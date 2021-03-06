#include <Eigen/Geometry>

#include "cupoch/utility/eigen.h"

using namespace cupoch;
using namespace cupoch::utility;

Eigen::Matrix4f cupoch::utility::TransformVector6fToMatrix4f(
        const Eigen::Vector6f &input) {
    Eigen::Matrix4f output = Eigen::Matrix4f::Identity();
    output.block<3, 3>(0, 0) =
            (Eigen::AngleAxisf(input(2), Eigen::Vector3f::UnitZ()) *
             Eigen::AngleAxisf(input(1), Eigen::Vector3f::UnitY()) *
             Eigen::AngleAxisf(input(0), Eigen::Vector3f::UnitX()))
                    .matrix();
    output.block<3, 1>(0, 3) = input.block<3, 1>(3, 0);
    return output;
}

template <int Dim>
thrust::tuple<bool, Eigen::Matrix<float, Dim, 1>>
cupoch::utility::SolveLinearSystemPSD(const Eigen::Matrix<float, Dim, Dim> &A,
                                      const Eigen::Matrix<float, Dim, 1> &b,
                                      bool check_symmetric,
                                      bool check_det) {
    // PSD implies symmetric
    if (check_symmetric && !A.isApprox(A.transpose())) {
        LogWarning("check_symmetric failed, empty vector will be returned");
        return thrust::make_tuple(false, Eigen::Matrix<float, Dim, 1>::Zero());
    }

    if (check_det) {
        float det = A.determinant();
        if (fabs(det) < 1e-6 || std::isnan(det) || std::isinf(det)) {
            LogWarning("check_det failed, empty vector will be returned");
            return thrust::make_tuple(false,
                                      Eigen::Matrix<float, Dim, 1>::Zero());
        }
    }

    Eigen::Matrix<float, Dim, 1> x;

    x = A.ldlt().solve(b);
    return thrust::make_tuple(true, std::move(x));
}

thrust::tuple<bool, Eigen::Matrix4f>
cupoch::utility::SolveJacobianSystemAndObtainExtrinsicMatrix(
        const Eigen::Matrix6f &JTJ, const Eigen::Vector6f &JTr) {
    bool solution_exist;
    Eigen::Vector6f x;
    thrust::tie(solution_exist, x) =
            SolveLinearSystemPSD(JTJ, Eigen::Vector6f(-JTr));

    if (solution_exist) {
        Eigen::Matrix4f extrinsic = TransformVector6fToMatrix4f(x);
        return thrust::make_tuple(solution_exist, std::move(extrinsic));
    } else {
        return thrust::make_tuple(false, Eigen::Matrix4f::Identity());
    }
}

template thrust::tuple<bool, Eigen::Vector6f>
cupoch::utility::SolveLinearSystemPSD(const Eigen::Matrix6f &A,
                                      const Eigen::Vector6f &b,
                                      bool check_symmetric,
                                      bool check_det);

Eigen::Matrix3f cupoch::utility::RotationMatrixX(float radians) {
    Eigen::Matrix3f rot;
    rot << 1, 0, 0, 0, std::cos(radians), -std::sin(radians), 0,
            std::sin(radians), std::cos(radians);
    return rot;
}

Eigen::Matrix3f cupoch::utility::RotationMatrixY(float radians) {
    Eigen::Matrix3f rot;
    rot << std::cos(radians), 0, std::sin(radians), 0, 1, 0, -std::sin(radians),
            0, std::cos(radians);
    return rot;
}

Eigen::Matrix3f cupoch::utility::RotationMatrixZ(float radians) {
    Eigen::Matrix3f rot;
    rot << std::cos(radians), -std::sin(radians), 0, std::sin(radians),
            std::cos(radians), 0, 0, 0, 1;
    return rot;
}