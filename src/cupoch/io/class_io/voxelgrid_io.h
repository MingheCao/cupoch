#pragma once

#include <string>

#include "cupoch/geometry/voxelgrid.h"

namespace cupoch {
namespace io {

struct HostVoxelGrid {
    HostVoxelGrid() = default;
    ~HostVoxelGrid() = default;
    void FromDevice(const geometry::VoxelGrid& voxelgrid);
    void ToDevice(geometry::VoxelGrid& voxelgrid) const;
    void Clear();
    thrust::host_vector<Eigen::Vector3i> voxels_keys_;
    thrust::host_vector<geometry::Voxel> voxels_values_;
};

/// Factory function to create a voxelgrid from a file.
/// \return return an empty voxelgrid if fail to read the file.
std::shared_ptr<geometry::VoxelGrid> CreateVoxelGridFromFile(
        const std::string &filename,
        const std::string &format = "auto",
        bool print_progress = false);

/// The general entrance for reading a VoxelGrid from a file
/// The function calls read functions based on the extension name of filename.
/// \return return true if the read function is successful, false otherwise.
bool ReadVoxelGrid(const std::string &filename,
                   geometry::VoxelGrid &voxelgrid,
                   const std::string &format = "auto",
                   bool print_progress = false);

/// The general entrance for writing a VoxelGrid to a file
/// The function calls write functions based on the extension name of filename.
/// If the write function supports binary encoding and compression, the later
/// two parameters will be used. Otherwise they will be ignored.
/// \return return true if the write function is successful, false otherwise.
bool WriteVoxelGrid(const std::string &filename,
                    const geometry::VoxelGrid &voxelgrid,
                    bool write_ascii = false,
                    bool compressed = false,
                    bool print_progress = false);

bool ReadVoxelGridFromPLY(const std::string &filename,
                          geometry::VoxelGrid &voxelgrid,
                          bool print_progress = false);

bool WriteVoxelGridToPLY(const std::string &filename,
                         const geometry::VoxelGrid &voxelgrid,
                         bool write_ascii = false,
                         bool compressed = false,
                         bool print_progress = false);

}  // namespace io
}  // namespace cupoch