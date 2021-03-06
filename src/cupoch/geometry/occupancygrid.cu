#include "cupoch/geometry/occupancygrid.h"
#include "cupoch/geometry/densegrid.inl"
#include "cupoch/geometry/intersection_test.h"
#include "cupoch/geometry/boundingvolume.h"
#include "cupoch/geometry/pointcloud.h"
#include "cupoch/geometry/geometry_functor.h"

#include "cupoch/utility/eigen.h"
#include <thrust/iterator/discard_iterator.h>

namespace cupoch {
namespace geometry {

namespace {

__constant__ float voxel_offset[7][3] = {{0, 0, 0}, {1, 0, 0}, {-1, 0, 0},
                                         {0, 1, 0}, {0, -1, 0}, {0, 0, 1},
                                         {0, 0, -1}};

struct extract_index_and_prob_functor {
    __device__ thrust::tuple<Eigen::Vector3i, float> operator() (const OccupancyVoxel& v) const {
        return thrust::make_tuple(v.grid_index_, v.prob_log_);
    }
};

struct compute_intersect_voxel_segment_functor{
    compute_intersect_voxel_segment_functor(const Eigen::Vector3f* points,
                                            const Eigen::Vector3f* steps,
                                            const Eigen::Vector3f& viewpoint,
                                            const Eigen::Vector3i& half_resolution,
                                            float voxel_size,
                                            const Eigen::Vector3f& origin,
                                            int n_div)
                                            : points_(points), steps_(steps), viewpoint_(viewpoint),
                                             half_resolution_(half_resolution), voxel_size_(voxel_size),
                                             box_half_size_(Eigen::Vector3f(
                                                voxel_size / 2, voxel_size / 2, voxel_size / 2)),
                                             origin_(origin), n_div_(n_div) {};
    const Eigen::Vector3f* points_;
    const Eigen::Vector3f* steps_;
    const Eigen::Vector3f viewpoint_;
    const Eigen::Vector3i half_resolution_;
    const float voxel_size_;
    const Eigen::Vector3f box_half_size_;
    const Eigen::Vector3f origin_;
    const int n_div_;
    __device__ Eigen::Vector3i operator() (size_t idx) {
        int pidx = idx / (n_div_ * 7);
        int svidx = idx % (n_div_ * 7);
        int sidx = svidx / 7;
        int vidx = svidx % 7;
        Eigen::Vector3f center = sidx * steps_[pidx] + viewpoint_;
        Eigen::Vector3f voxel_idx = Eigen::device_vectorize<float, 3, ::floor>((center - origin_) / voxel_size_);
        Eigen::Vector3f voxel_center = voxel_size_ * (voxel_idx + Eigen::Vector3f(voxel_offset[vidx][0], voxel_offset[vidx][1], voxel_offset[vidx][2]));
        bool is_intersect = intersection_test::LineSegmentAABB(viewpoint_, points_[pidx],
                                                               voxel_center - box_half_size_,
                                                               voxel_center + box_half_size_);
        return (is_intersect) ? voxel_idx.cast<int>() + half_resolution_ :
            Eigen::Vector3i(geometry::INVALID_VOXEL_INDEX, geometry::INVALID_VOXEL_INDEX, geometry::INVALID_VOXEL_INDEX);
    }
};

void ComputeFreeVoxels(const utility::device_vector<Eigen::Vector3f>& points,
                       const Eigen::Vector3f& viewpoint,
                       float voxel_size, int resolution, Eigen::Vector3f& origin,
                       const utility::device_vector<Eigen::Vector3f>& steps, int n_div,
                       utility::device_vector<Eigen::Vector3i>& free_voxels) {
    if (points.empty()) return;
    size_t n_points = points.size();
    size_t max_idx = resolution * resolution * resolution;
    Eigen::Vector3i half_resolution = Eigen::Vector3i::Constant(resolution / 2);
    free_voxels.resize(n_div * n_points * 7);
    compute_intersect_voxel_segment_functor func(thrust::raw_pointer_cast(points.data()),
                                                 thrust::raw_pointer_cast(steps.data()),
                                                 viewpoint, half_resolution,
                                                 voxel_size, origin, n_div);
    thrust::transform(thrust::make_counting_iterator<size_t>(0), thrust::make_counting_iterator(n_div * n_points * 7),
                      free_voxels.begin(), func);
    auto end1 = thrust::remove_if(free_voxels.begin(), free_voxels.end(),
             [max_idx] __device__(
                    const Eigen::Vector3i &idx)
                    -> bool {
                return idx[0] < 0 || idx[1] < 0 || idx[2] < 0 || idx[0] >= max_idx || idx[1] >= max_idx || idx[2] >= max_idx;
            });
    free_voxels.resize(thrust::distance(free_voxels.begin(), end1));
    thrust::sort(free_voxels.begin(), free_voxels.end());
    auto end2 = thrust::unique(free_voxels.begin(), free_voxels.end());
    free_voxels.resize(thrust::distance(free_voxels.begin(), end2));
}

struct create_occupancy_voxels_functor {
    create_occupancy_voxels_functor(const Eigen::Vector3f &origin,
                                    const Eigen::Vector3i &half_resolution,
                                    float voxel_size)
        : origin_(origin),
          half_resolution_(half_resolution),
          voxel_size_(voxel_size) {};
    const Eigen::Vector3f origin_;
    const Eigen::Vector3i half_resolution_;
    const float voxel_size_;
    __device__ Eigen::Vector3i operator()(const thrust::tuple<Eigen::Vector3f, bool> &x) const {
        const Eigen::Vector3f& point = thrust::get<0>(x);
        bool hit_flag = thrust::get<1>(x);
        Eigen::Vector3f ref_coord = (point - origin_) / voxel_size_;
        return (hit_flag) ? Eigen::device_vectorize<float, 3, ::floor>(ref_coord).cast<int>() + half_resolution_ :
            Eigen::Vector3i(INVALID_VOXEL_INDEX,
                INVALID_VOXEL_INDEX,
                INVALID_VOXEL_INDEX);;
    }
};

void ComputeOccupiedVoxels(const utility::device_vector<Eigen::Vector3f>& points,
    const utility::device_vector<bool> hit_flags,
    float voxel_size, int resolution, Eigen::Vector3f& origin,
    utility::device_vector<Eigen::Vector3i>& occupied_voxels) {
    occupied_voxels.resize(points.size());
    size_t max_idx = resolution * resolution * resolution;
    Eigen::Vector3i half_resolution = Eigen::Vector3i::Constant(resolution / 2);
    create_occupancy_voxels_functor func(origin, half_resolution, voxel_size);
    thrust::transform(make_tuple_iterator(points.begin(), hit_flags.begin()),
                      make_tuple_iterator(points.end(), hit_flags.end()),
                      occupied_voxels.begin(), func);
    auto end1 = thrust::remove_if(occupied_voxels.begin(), occupied_voxels.end(),
             [max_idx] __device__(
                    const Eigen::Vector3i &idx)
                    -> bool {
                return idx[0] < 0 || idx[1] < 0 || idx[2] < 0 || idx[0] >= max_idx || idx[1] >= max_idx || idx[2] >= max_idx;
            });
    occupied_voxels.resize(thrust::distance(occupied_voxels.begin(), end1));
    thrust::sort(occupied_voxels.begin(), occupied_voxels.end());
    auto end2 = thrust::unique(occupied_voxels.begin(), occupied_voxels.end());
    occupied_voxels.resize(thrust::distance(occupied_voxels.begin(), end2));
}

struct add_occupancy_functor{
    add_occupancy_functor(OccupancyVoxel* voxels, int resolution,
                          float clamping_thres_min, float clamping_thres_max,
                          float prob_miss_log, float prob_hit_log, bool occupied)
     : voxels_(voxels), resolution_(resolution), clamping_thres_min_(clamping_thres_min), clamping_thres_max_(clamping_thres_max),
     prob_miss_log_(prob_miss_log), prob_hit_log_(prob_hit_log), occupied_(occupied) {};
    OccupancyVoxel* voxels_;
    const int resolution_;
    const float clamping_thres_min_;
    const float clamping_thres_max_;
    const float prob_miss_log_;
    const float prob_hit_log_;
    const bool occupied_;
    __device__ void operator() (const Eigen::Vector3i& voxel) {
        size_t idx = IndexOf(voxel, resolution_);
        float p = voxels_[idx].prob_log_;
        p = (isnan(p)) ? 0 : p;
        p += (occupied_) ? prob_hit_log_ : prob_miss_log_;
        voxels_[idx].prob_log_ = min(max(p, clamping_thres_min_), clamping_thres_max_);
        voxels_[idx].grid_index_ = voxel;
    }
};

}

template class DenseGrid<OccupancyVoxel>;

OccupancyGrid::OccupancyGrid()
 : DenseGrid<OccupancyVoxel>(Geometry::GeometryType::OccupancyGrid, 0.05, 512, Eigen::Vector3f::Zero()) {}
OccupancyGrid::OccupancyGrid(float voxel_size, int resolution, const Eigen::Vector3f& origin)
 : DenseGrid<OccupancyVoxel>(Geometry::GeometryType::OccupancyGrid, voxel_size, resolution, origin) {}
OccupancyGrid::~OccupancyGrid() {}
OccupancyGrid::OccupancyGrid(const OccupancyGrid& other)
 : DenseGrid<OccupancyVoxel>(Geometry::GeometryType::OccupancyGrid, other),
   clamping_thres_min_(other.clamping_thres_min_), clamping_thres_max_(other.clamping_thres_max_),
   prob_hit_log_(other.prob_hit_log_), prob_miss_log_(other.prob_miss_log_),
   occ_prob_thres_log_(other.occ_prob_thres_log_), visualize_free_area_(other.visualize_free_area_) {}

Eigen::Vector3f OccupancyGrid::GetMinBound() const {
    auto vs = ExtractKnownVoxels();
    if (vs.empty()) return origin_;
    OccupancyVoxel v = vs.front();
    return (v.grid_index_ - Eigen::Vector3i::Constant(resolution_ / 2)).cast<float>() * voxel_size_ - origin_;
}

Eigen::Vector3f OccupancyGrid::GetMaxBound() const {
    auto vs = ExtractKnownVoxels();
    if (vs.empty()) return origin_;
    OccupancyVoxel v = vs.back();
    return (v.grid_index_ - Eigen::Vector3i::Constant(resolution_ / 2 - 1)).cast<float>() * voxel_size_ - origin_;
}

bool OccupancyGrid::IsOccupied(const Eigen::Vector3f &point) const{
    auto idx = GetVoxelIndex(point);
    if (idx < 0) return false;
    OccupancyVoxel voxel = voxels_[idx];
    return !std::isnan(voxel.prob_log_) && voxel.prob_log_ > occ_prob_thres_log_;
}

bool OccupancyGrid::IsUnknown(const Eigen::Vector3f &point) const{
    auto idx = GetVoxelIndex(point);
    if (idx < 0) return true;
    OccupancyVoxel voxel = voxels_[idx];
    return std::isnan(voxel.prob_log_);
}

int OccupancyGrid::GetVoxelIndex(const Eigen::Vector3f& point) const {
    Eigen::Vector3f voxel_f = (point - origin_) / voxel_size_;
    int h_res = resolution_ / 2;
    Eigen::Vector3i voxel_idx = (Eigen::floor(voxel_f.array())).matrix().cast<int>() + Eigen::Vector3i::Constant(h_res);
    int idx = IndexOf(voxel_idx, resolution_);
    if (idx < 0 || idx >= resolution_ * resolution_ * resolution_) return -1;
    return idx;
}

thrust::tuple<bool, OccupancyVoxel> OccupancyGrid::GetVoxel(const Eigen::Vector3f &point) const {
    auto idx = GetVoxelIndex(point);
    if (idx < 0) return thrust::make_tuple(false, OccupancyVoxel());
    OccupancyVoxel voxel = voxels_[idx];
    return thrust::make_tuple(!std::isnan(voxel.prob_log_), voxel);
}

size_t OccupancyGrid::CountKnownVoxels() const {
    return thrust::count_if(voxels_.begin(), voxels_.end(),
        [] __device__ (const OccupancyVoxel& v) {
            return !isnan(v.prob_log_);
        });
}

size_t OccupancyGrid::CountFreeVoxels() const {
    return thrust::count_if(voxels_.begin(), voxels_.end(),
        [th = occ_prob_thres_log_] __device__ (const OccupancyVoxel& v) {
            return !isnan(v.prob_log_) && v.prob_log_ <= th;
        });
}

size_t OccupancyGrid::CountOccupiedVoxels() const {
    return thrust::count_if(voxels_.begin(), voxels_.end(),
        [th = occ_prob_thres_log_] __device__ (const OccupancyVoxel& v) {
            return !isnan(v.prob_log_) && v.prob_log_ > th;
        });
}

utility::device_vector<OccupancyVoxel> OccupancyGrid::ExtractKnownVoxels() const {
    size_t n_out = CountKnownVoxels();
    utility::device_vector<OccupancyVoxel> out(n_out);
    thrust::copy_if(voxels_.begin(), voxels_.end(), out.begin(),
        [] __device__ (const OccupancyVoxel& v) {
            return !isnan(v.prob_log_);
        });
    return out;
}

utility::device_vector<OccupancyVoxel> OccupancyGrid::ExtractFreeVoxels() const {
    size_t n_out = CountFreeVoxels();
    utility::device_vector<OccupancyVoxel> out(n_out);
    thrust::copy_if(voxels_.begin(), voxels_.end(), out.begin(),
        [th = occ_prob_thres_log_] __device__ (const OccupancyVoxel& v) {
            return !isnan(v.prob_log_) && v.prob_log_ <= th;
        });
    return out;
}

utility::device_vector<OccupancyVoxel> OccupancyGrid::ExtractOccupiedVoxels() const {
    size_t n_out = CountOccupiedVoxels();
    utility::device_vector<OccupancyVoxel> out(n_out);
    thrust::copy_if(voxels_.begin(), voxels_.end(), out.begin(),
        [th = occ_prob_thres_log_] __device__ (const OccupancyVoxel& v) {
            return !isnan(v.prob_log_) && v.prob_log_ > th;
        });
    return out;
}

utility::device_vector<Eigen::Vector3i> OccupancyGrid::ExtractKnownVoxelIndices() const{
    size_t n_out = CountKnownVoxels();
    utility::device_vector<Eigen::Vector3i> out(n_out);
    thrust::copy_if(thrust::make_transform_iterator(voxels_.begin(), extract_index_and_prob_functor()),
        thrust::make_transform_iterator(voxels_.end(), extract_index_and_prob_functor()),
        make_tuple_iterator(out.begin(), thrust::make_discard_iterator()),
        [] __device__ (const thrust::tuple<Eigen::Vector3i, float> x) {
            float p = thrust::get<1>(x);
            return !isnan(p);
        });
    return out;
}

utility::device_vector<Eigen::Vector3i> OccupancyGrid::ExtractFreeVoxelIndices() const{
    size_t n_out = CountFreeVoxels();
    utility::device_vector<Eigen::Vector3i> out(n_out);
    thrust::copy_if(thrust::make_transform_iterator(voxels_.begin(), extract_index_and_prob_functor()),
        thrust::make_transform_iterator(voxels_.end(), extract_index_and_prob_functor()),
        make_tuple_iterator(out.begin(), thrust::make_discard_iterator()),
        [th = occ_prob_thres_log_] __device__ (const thrust::tuple<Eigen::Vector3i, float> x) {
            float p = thrust::get<1>(x);
            return !isnan(p) && p <= th;
        });
    return out;
}

utility::device_vector<Eigen::Vector3i> OccupancyGrid::ExtractOccupiedVoxelIndices() const{
    size_t n_out = CountOccupiedVoxels();
    utility::device_vector<Eigen::Vector3i> out(n_out);
    thrust::copy_if(thrust::make_transform_iterator(voxels_.begin(), extract_index_and_prob_functor()),
        thrust::make_transform_iterator(voxels_.end(), extract_index_and_prob_functor()),
        make_tuple_iterator(out.begin(), thrust::make_discard_iterator()),
        [th = occ_prob_thres_log_] __device__ (const thrust::tuple<Eigen::Vector3i, float> x) {
            float p = thrust::get<1>(x);
            return !isnan(p) && p > th;
        });
    return out;
}

void OccupancyGrid::ExtractKnownVoxelIndices(utility::device_vector<Eigen::Vector3i>& indices) const {
    indices = ExtractKnownVoxelIndices();
}

OccupancyGrid& OccupancyGrid::ReconstructVoxels(float voxel_size, int resolution) {
    voxel_size_ = voxel_size;
    resolution_ = resolution;
    voxels_.resize(resolution_ * resolution_ * resolution_, OccupancyVoxel());
    return *this;
}

OccupancyGrid& OccupancyGrid::Insert(const utility::device_vector<Eigen::Vector3f>& points,
                                     const Eigen::Vector3f& viewpoint, float max_range) {
    if (points.empty()) return *this;

    utility::device_vector<Eigen::Vector3f> ranged_points(points.size());
    utility::device_vector<float> ranged_dists(points.size());
    utility::device_vector<bool> hit_flags(points.size());

    thrust::transform(points.begin(), points.end(),
                      make_tuple_iterator(ranged_points.begin(), ranged_dists.begin(), hit_flags.begin()),
                      [viewpoint, max_range] __device__ (const Eigen::Vector3f &pt) {
                          Eigen::Vector3f pt_vp = pt - viewpoint;
                          float dist = pt_vp.norm();
                          bool is_hit = max_range < 0 || dist <= max_range;
                          return thrust::make_tuple((is_hit) ? pt : viewpoint + pt_vp / dist * max_range,
                                                    (is_hit) ? dist : max_range, is_hit);
                      });
    float max_dist = *(thrust::max_element(ranged_dists.begin(), ranged_dists.end()));
    int n_div = int(std::ceil(max_dist / voxel_size_));

    utility::device_vector<Eigen::Vector3i> free_voxels;
    utility::device_vector<Eigen::Vector3i> occupied_voxels;
    if (n_div > 0) {
        utility::device_vector<Eigen::Vector3f> steps(points.size());
        thrust::transform(ranged_points.begin(), ranged_points.end(), steps.begin(),
                          [viewpoint, n_div] __device__ (const Eigen::Vector3f& pt) {
                              return (pt - viewpoint) / n_div;
                          });
        // comupute free voxels
        ComputeFreeVoxels(ranged_points, viewpoint, voxel_size_, resolution_, origin_, steps, n_div + 1, free_voxels);
    } else {
        thrust::copy(points.begin(), points.end(), ranged_points.begin());
        thrust::fill(hit_flags.begin(), hit_flags.end(), true);
    }
    // compute occupied voxels
    ComputeOccupiedVoxels(ranged_points, hit_flags, voxel_size_, resolution_, origin_, occupied_voxels);

    if (n_div > 0) {
        utility::device_vector<Eigen::Vector3i> free_voxels_res(free_voxels.size());
        auto end = thrust::set_difference(free_voxels.begin(), free_voxels.end(),
                                          occupied_voxels.begin(), occupied_voxels.end(),
                                          free_voxels_res.begin());
        free_voxels_res.resize(thrust::distance(free_voxels_res.begin(), end));
        AddVoxels(free_voxels_res, false);
    }
    AddVoxels(occupied_voxels, true);
    return *this;
}

OccupancyGrid& OccupancyGrid::Insert(const thrust::host_vector<Eigen::Vector3f>& points,
                                     const Eigen::Vector3f& viewpoint, float max_range) {
    utility::device_vector<Eigen::Vector3f> dev_points = points;
    return Insert(dev_points, viewpoint, max_range);
}

OccupancyGrid& OccupancyGrid::Insert(const geometry::PointCloud& pointcloud,
                                     const Eigen::Vector3f& viewpoint, float max_range) {
    Insert(pointcloud.points_, viewpoint, max_range);
    return *this;
}

OccupancyGrid& OccupancyGrid::AddVoxel(const Eigen::Vector3i &voxel, bool occupied) {
    int idx = IndexOf(voxel, resolution_);
    size_t max_idx = resolution_ * resolution_ * resolution_;
    if (idx < 0 || idx >= max_idx) {
        return *this;
    } else {
        OccupancyVoxel org_ov = voxels_[idx];
        if (std::isnan(org_ov.prob_log_)) org_ov.prob_log_ = 0.0;
        org_ov.prob_log_ += (occupied) ? prob_hit_log_ : prob_miss_log_;
        org_ov.prob_log_ = std::min(std::max(org_ov.prob_log_, clamping_thres_min_), clamping_thres_max_);
        org_ov.grid_index_ = voxel;
        voxels_[idx] = org_ov;
    }
    return *this;
}

OccupancyGrid& OccupancyGrid::AddVoxels(const utility::device_vector<Eigen::Vector3i>& voxels, bool occupied) {
    add_occupancy_functor func(thrust::raw_pointer_cast(voxels_.data()),
                               resolution_, clamping_thres_min_, clamping_thres_max_,
                               prob_miss_log_, prob_hit_log_, occupied);
    thrust::for_each(voxels.begin(), voxels.end(), func);
    return *this;
}

}
}