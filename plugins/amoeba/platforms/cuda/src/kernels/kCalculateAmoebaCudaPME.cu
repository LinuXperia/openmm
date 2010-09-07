//-----------------------------------------------------------------------------------------

//-----------------------------------------------------------------------------------------

#include "amoebaGpuTypes.h"
#include "amoebaCudaKernels.h"

//#define AMOEBA_DEBUG

static __constant__ cudaGmxSimulation cSim;
static __constant__ cudaAmoebaGmxSimulation cAmoebaSim;

void SetCalculateAmoebaPMESim(amoebaGpuContext amoebaGpu)
{
    cudaError_t status;
    gpuContext gpu = amoebaGpu->gpuContext;
    status         = cudaMemcpyToSymbol(cSim, &gpu->sim, sizeof(cudaGmxSimulation));
    RTERROR(status, "SetCalculateAmoebaPMESim: cudaMemcpyToSymbol: SetSim copy to cSim failed");
    status         = cudaMemcpyToSymbol(cAmoebaSim, &amoebaGpu->amoebaSim, sizeof(cudaAmoebaGmxSimulation));
    RTERROR(status, "SetCalculateAmoebaPMESim: cudaMemcpyToSymbol: SetSim copy to cAmoebaSim failed");
}

#define ARRAY(x,y) array[(x)-1+((y)-1)*AMOEBA_PME_ORDER]

/**
 * This is called from computeBsplines().  It calculates the spline coefficients for a single atom along a single axis.
 */
__device__ void computeBSplinePoint(float4* thetai, float w, float* array)
{
//      real*8 thetai(4,AMOEBA_PME_ORDER)
//      real*8 array(AMOEBA_PME_ORDER,AMOEBA_PME_ORDER)

    // initialization to get to 2nd order recursion

    ARRAY(2,2) = w;
    ARRAY(2,1) = 1.0f - w;

    // perform one pass to get to 3rd order recursion

    ARRAY(3,3) = 0.5f * w * ARRAY(2,2);
    ARRAY(3,2) = 0.5f * ((1.0f+w)*ARRAY(2,1)+(2.0f-w)*ARRAY(2,2));
    ARRAY(3,1) = 0.5f * (1.0f-w) * ARRAY(2,1);

    // compute standard B-spline recursion to desired order

    for (int i = 4; i <= AMOEBA_PME_ORDER; i++)
    {
        int k = i - 1;
        float denom = 1.0f / k;
        ARRAY(i,i) = denom * w * ARRAY(k,k);
        for (int j = 1; j <= i-2; j++)
            ARRAY(i,i-j) = denom * ((w+j)*ARRAY(k,i-j-1)+(i-j-w)*ARRAY(k,i-j));
        ARRAY(i,1) = denom * (1.0f-w) * ARRAY(k,1);
    }

    // get coefficients for the B-spline first derivative

    int k = AMOEBA_PME_ORDER - 1;
    ARRAY(k,AMOEBA_PME_ORDER) = ARRAY(k,AMOEBA_PME_ORDER-1);
    for (int i = AMOEBA_PME_ORDER-1; i >= 2; i--)
        ARRAY(k,i) = ARRAY(k,i-1) - ARRAY(k,i);
    ARRAY(k,1) = -ARRAY(k,1);

    // get coefficients for the B-spline second derivative

    k = AMOEBA_PME_ORDER - 2;
    ARRAY(k,AMOEBA_PME_ORDER-1) = ARRAY(k,AMOEBA_PME_ORDER-2);
    for (int i = AMOEBA_PME_ORDER-2; i >= 2; i--)
        ARRAY(k,i) = ARRAY(k,i-1) - ARRAY(k,i);
    ARRAY(k,1) = -ARRAY(k,1);
    ARRAY(k,AMOEBA_PME_ORDER) = ARRAY(k,AMOEBA_PME_ORDER-1);
    for (int i = AMOEBA_PME_ORDER-1; i >= 2; i--)
        ARRAY(k,i) = ARRAY(k,i-1) - ARRAY(k,i);
    ARRAY(k,1) = -ARRAY(k,1);

    // get coefficients for the B-spline third derivative

    k = AMOEBA_PME_ORDER - 3;
    ARRAY(k,AMOEBA_PME_ORDER-2) = ARRAY(k,AMOEBA_PME_ORDER-3);
    for (int i = AMOEBA_PME_ORDER-3; i >= 2; i--)
        ARRAY(k,i) = ARRAY(k,i-1) - ARRAY(k,i);
    ARRAY(k,1) = -ARRAY(k,1);
    ARRAY(k,AMOEBA_PME_ORDER-1) = ARRAY(k,AMOEBA_PME_ORDER-2);
    for (int i = AMOEBA_PME_ORDER-2; i >= 2; i--)
        ARRAY(k,i) = ARRAY(k,i-1) - ARRAY(k,i);
    ARRAY(k,1) = -ARRAY(k,1);
    ARRAY(k,AMOEBA_PME_ORDER) = ARRAY(k,AMOEBA_PME_ORDER-1);
    for (int i = AMOEBA_PME_ORDER-1; i >= 2; i--)
        ARRAY(k,i) = ARRAY(k,i-1) - ARRAY(k,i);
    ARRAY(k,1) = -ARRAY(k,1);

    // copy coefficients from temporary to permanent storage

    for (int i = 1; i <= AMOEBA_PME_ORDER; i++)
        thetai[i] = make_float4(ARRAY(AMOEBA_PME_ORDER,i), ARRAY(AMOEBA_PME_ORDER-1,i), ARRAY(AMOEBA_PME_ORDER-2,i), ARRAY(AMOEBA_PME_ORDER-3,i));
}

/**
 * Compute bspline coefficients.
 */
__global__
#if (__CUDA_ARCH__ >= 200)
__launch_bounds__(256, 1)
#elif (__CUDA_ARCH__ >= 120)
__launch_bounds__(256, 1)
#else
__launch_bounds__(128, 1)
#endif
void kComputeBsplines_kernel()
{
    extern __shared__ float bsplines_cache[]; // size = block_size*pme_order*pme_order
    float* array = &bsplines_cache[threadIdx.x*AMOEBA_PME_ORDER*AMOEBA_PME_ORDER];

    //  get the B-spline coefficients for each multipole site

    for (int i = blockIdx.x*blockDim.x+threadIdx.x; i < cSim.atoms; i += blockDim.x*gridDim.x) {
        float4 posq = cSim.pPosq[i];
        posq.x -= floor(posq.x*cSim.invPeriodicBoxSizeX)*cSim.periodicBoxSizeX;
        posq.y -= floor(posq.y*cSim.invPeriodicBoxSizeY)*cSim.periodicBoxSizeY;
        posq.z -= floor(posq.z*cSim.invPeriodicBoxSizeZ)*cSim.periodicBoxSizeZ;
        float3 t = make_float3((posq.x*cSim.invPeriodicBoxSizeX)*cSim.pmeGridSize.x,
                               (posq.y*cSim.invPeriodicBoxSizeY)*cSim.pmeGridSize.y,
                               (posq.z*cSim.invPeriodicBoxSizeZ)*cSim.pmeGridSize.z);

        // First axis.

        float w = posq.x*cSim.invPeriodicBoxSizeX;
        float fr = cSim.pmeGridSize.x*(w-(int)(w+0.5f)+0.5f);
        int ifr = (int) fr;
        w = fr - ifr;
        int igrid1 = ifr - AMOEBA_PME_ORDER;
        computeBSplinePoint(&cAmoebaSim.pThetai1[i*AMOEBA_PME_ORDER], w, array);

        // Second axis.

        w = posq.y*cSim.invPeriodicBoxSizeY;
        fr = cSim.pmeGridSize.y*(w-(int)(w+0.5f)+0.5f);
        ifr = (int) fr;
        w = fr - ifr;
        int igrid2 = ifr - AMOEBA_PME_ORDER;
        computeBSplinePoint(&cAmoebaSim.pThetai2[i*AMOEBA_PME_ORDER], w, array);

        // Third axis.

        w = posq.z*cSim.invPeriodicBoxSizeZ;
        fr = cSim.pmeGridSize.z*(w-(int)(w+0.5f)+0.5f);
        ifr = (int) fr;
        w = fr - ifr;
        int igrid3 = ifr - AMOEBA_PME_ORDER;
        computeBSplinePoint(&cAmoebaSim.pThetai3[i*AMOEBA_PME_ORDER], w, array);

        // Record the grid point.

        cAmoebaSim.pIgrid[i] = make_int4(igrid1, igrid2, igrid3, 0);
        cSim.pPmeAtomGridIndex[i] = make_int2(i, igrid1*cSim.pmeGridSize.y*cSim.pmeGridSize.z+igrid2*cSim.pmeGridSize.z+igrid3);
    }
}

__global__
#if (__CUDA_ARCH__ >= 200)
__launch_bounds__(1024, 1)
#elif (__CUDA_ARCH__ >= 120)
__launch_bounds__(512, 1)
#else
__launch_bounds__(256, 1)
#endif
void kGridSpreadMultipoles_kernel()
{
    unsigned int numGridPoints = cSim.pmeGridSize.x*cSim.pmeGridSize.y*cSim.pmeGridSize.z;
    unsigned int numThreads = gridDim.x*blockDim.x;
    for (int gridIndex = blockIdx.x*blockDim.x+threadIdx.x; gridIndex < numGridPoints; gridIndex += numThreads)
    {
        int3 gridPoint;
        gridPoint.x = gridIndex/(cSim.pmeGridSize.y*cSim.pmeGridSize.z);
        int remainder = gridIndex-gridPoint.x*cSim.pmeGridSize.y*cSim.pmeGridSize.z;
        gridPoint.y = remainder/cSim.pmeGridSize.z;
        gridPoint.z = remainder-gridPoint.y*cSim.pmeGridSize.z;
        float result = 0.0f;
        for (int ix = 0; ix < PME_ORDER; ++ix)
        {
            int x = gridPoint.x-ix+(gridPoint.x >= ix ? 0 : cSim.pmeGridSize.x);
            for (int iy = 0; iy < PME_ORDER; ++iy)
            {
                int y = gridPoint.y-iy+(gridPoint.y >= iy ? 0 : cSim.pmeGridSize.y);
                int z1 = gridPoint.z-PME_ORDER+1;
                z1 += (z1 >= 0 ? 0 : cSim.pmeGridSize.z);
                int z2 = (z1 < gridPoint.z ? gridPoint.z : cSim.pmeGridSize.z-1);
                int gridIndex1 = x*cSim.pmeGridSize.y*cSim.pmeGridSize.z+y*cSim.pmeGridSize.z+z1;
                int gridIndex2 = x*cSim.pmeGridSize.y*cSim.pmeGridSize.z+y*cSim.pmeGridSize.z+z2;
                int firstAtom = cSim.pPmeAtomRange[gridIndex1];
                int lastAtom = cSim.pPmeAtomRange[gridIndex2+1];
                for (int i = firstAtom; i < lastAtom; ++i)
                {
                    int2 atomData = cSim.pPmeAtomGridIndex[i];
                    int atomIndex = atomData.x;
                    int z = atomData.y;
                    int iz = gridPoint.z-z+(gridPoint.z >= z ? 0 : cSim.pmeGridSize.z);
                    float atomCharge = cSim.pPosq[atomIndex].w;
                    float atomDipoleX = cAmoebaSim.pLabFrameDipole[atomIndex+3];
                    float atomDipoleY = cAmoebaSim.pLabFrameDipole[atomIndex+3+1];
                    float atomDipoleZ = cAmoebaSim.pLabFrameDipole[atomIndex+3+2];
                    float atomQuadrupoleXX = cAmoebaSim.pLabFrameQuadrupole[atomIndex+9];
                    float atomQuadrupoleXY = 2*cAmoebaSim.pLabFrameQuadrupole[atomIndex+9+1];
                    float atomQuadrupoleXZ = 2*cAmoebaSim.pLabFrameQuadrupole[atomIndex+9+2];
                    float atomQuadrupoleYY = cAmoebaSim.pLabFrameQuadrupole[atomIndex+9+4];
                    float atomQuadrupoleYZ = 2*cAmoebaSim.pLabFrameQuadrupole[atomIndex+9+5];
                    float atomQuadrupoleZZ = cAmoebaSim.pLabFrameQuadrupole[atomIndex+9+8];
                    float4 t = cAmoebaSim.pThetai1[atomIndex+ix*cSim.atoms];
                    float4 u = cAmoebaSim.pThetai2[atomIndex+iy*cSim.atoms];
                    float4 v = cAmoebaSim.pThetai3[atomIndex+iz*cSim.atoms];
                    float term0 = atomCharge*u.x*v.x + atomDipoleY*u.y*v.x + atomDipoleZ*u.x*v.y + atomQuadrupoleYY*u.z*v.x + atomQuadrupoleZZ*u.x*v.z + atomQuadrupoleYZ*u.y*v.y;
                    float term1 = atomDipoleX*u.x*v.x + atomQuadrupoleXY*u.y*v.x + atomQuadrupoleXZ*u.x*v.y;
                    float term2 = atomQuadrupoleXX * u.x * v.x;
                    result += term0*t.x + term1*t.y + term2*t.z;
                }
                if (z1 > gridPoint.z)
                {
                    gridIndex1 = x*cSim.pmeGridSize.y*cSim.pmeGridSize.z+y*cSim.pmeGridSize.z;
                    gridIndex2 = x*cSim.pmeGridSize.y*cSim.pmeGridSize.z+y*cSim.pmeGridSize.z+gridPoint.z;
                    firstAtom = cSim.pPmeAtomRange[gridIndex1];
                    lastAtom = cSim.pPmeAtomRange[gridIndex2+1];
                    for (int i = firstAtom; i < lastAtom; ++i)
                    {
                        int2 atomData = cSim.pPmeAtomGridIndex[i];
                        int atomIndex = atomData.x;
                        int z = atomData.y;
                        int iz = gridPoint.z-z+(gridPoint.z >= z ? 0 : cSim.pmeGridSize.z);
                        float atomCharge = cSim.pPosq[atomIndex].w;
                        float atomDipoleX = cAmoebaSim.pLabFrameDipole[atomIndex+3];
                        float atomDipoleY = cAmoebaSim.pLabFrameDipole[atomIndex+3+1];
                        float atomDipoleZ = cAmoebaSim.pLabFrameDipole[atomIndex+3+2];
                        float atomQuadrupoleXX = cAmoebaSim.pLabFrameQuadrupole[atomIndex+9];
                        float atomQuadrupoleXY = 2*cAmoebaSim.pLabFrameQuadrupole[atomIndex+9+1];
                        float atomQuadrupoleXZ = 2*cAmoebaSim.pLabFrameQuadrupole[atomIndex+9+2];
                        float atomQuadrupoleYY = cAmoebaSim.pLabFrameQuadrupole[atomIndex+9+4];
                        float atomQuadrupoleYZ = 2*cAmoebaSim.pLabFrameQuadrupole[atomIndex+9+5];
                        float atomQuadrupoleZZ = cAmoebaSim.pLabFrameQuadrupole[atomIndex+9+8];
                        float4 t = cAmoebaSim.pThetai1[atomIndex+ix*cSim.atoms];
                        float4 u = cAmoebaSim.pThetai2[atomIndex+iy*cSim.atoms];
                        float4 v = cAmoebaSim.pThetai3[atomIndex+iz*cSim.atoms];
                        float term0 = atomCharge*u.x*v.x + atomDipoleY*u.y*v.x + atomDipoleZ*u.x*v.y + atomQuadrupoleYY*u.z*v.x + atomQuadrupoleZZ*u.x*v.z + atomQuadrupoleYZ*u.y*v.y;
                        float term1 = atomDipoleX*u.x*v.x + atomQuadrupoleXY*u.y*v.x + atomQuadrupoleXZ*u.x*v.y;
                        float term2 = atomQuadrupoleXX * u.x * v.x;
                        result += term0*t.x + term1*t.y + term2*t.z;
                    }
                }
            }
        }
        cSim.pPmeGrid[gridIndex] = make_cuComplex(result, 0.0f);
    }
}

__global__
#if (__CUDA_ARCH__ >= 200)
__launch_bounds__(1024, 1)
#elif (__CUDA_ARCH__ >= 120)
__launch_bounds__(512, 1)
#else
__launch_bounds__(256, 1)
#endif
void kComputeFixedPotentialFromGrid_kernel()
{
    // extract the permanent multipole field at each site

    for (int m = blockIdx.x*blockDim.x+threadIdx.x; m < cSim.atoms; m += blockDim.x*gridDim.x) {
        int4 grid = cAmoebaSim.pIgrid[m];
        float tuv000 = 0.0f;
        float tuv001 = 0.0f;
        float tuv010 = 0.0f;
        float tuv100 = 0.0f;
        float tuv200 = 0.0f;
        float tuv020 = 0.0f;
        float tuv002 = 0.0f;
        float tuv110 = 0.0f;
        float tuv101 = 0.0f;
        float tuv011 = 0.0f;
        float tuv300 = 0.0f;
        float tuv030 = 0.0f;
        float tuv003 = 0.0f;
        float tuv210 = 0.0f;
        float tuv201 = 0.0f;
        float tuv120 = 0.0f;
        float tuv021 = 0.0f;
        float tuv102 = 0.0f;
        float tuv012 = 0.0f;
        float tuv111 = 0.0f;
        for (int it3 = 0; it3 < AMOEBA_PME_ORDER; it3++) {
            int k = grid.z+it3-(grid.z+it3 >= cSim.pmeGridSize.z ? cSim.pmeGridSize.z : 0);
            float4 v = cAmoebaSim.pThetai3[m*AMOEBA_PME_ORDER+it3];
            float tu00 = 0.0f;
            float tu10 = 0.0f;
            float tu01 = 0.0f;
            float tu20 = 0.0f;
            float tu11 = 0.0f;
            float tu02 = 0.0f;
            float tu30 = 0.0f;
            float tu21 = 0.0f;
            float tu12 = 0.0f;
            float tu03 = 0.0f;
            for (int it2 = 0; it2 < AMOEBA_PME_ORDER; it2++) {
                int j = grid.y+it2-(grid.y+it2 >= cSim.pmeGridSize.y ? cSim.pmeGridSize.y : 0);
                float4 u = cAmoebaSim.pThetai2[m*AMOEBA_PME_ORDER+it2];
                float4 t = make_float4(0.0f, 0.0f, 0.0f, 0.0f);
                for (int it1 = 0; it1 < AMOEBA_PME_ORDER; it1++) {
                    int i = grid.x+it1-(grid.x+it1 >= cSim.pmeGridSize.x ? cSim.pmeGridSize.x : 0);
                    int gridIndex = i*cSim.pmeGridSize.y*cSim.pmeGridSize.z + j*cSim.pmeGridSize.z + k;
                    float tq = cSim.pPmeGrid[gridIndex].x;
                    float4 tadd = cAmoebaSim.pThetai1[m*AMOEBA_PME_ORDER+it1];
                    t.x += tq*tadd.x;
                    t.y += tq*tadd.y;
                    t.z += tq*tadd.z;
                    t.w += tq*tadd.w;
                }
                tu00 += t.x*u.x;
                tu10 += t.y*u.x;
                tu01 += t.x*u.y;
                tu20 += t.z*u.x;
                tu11 += t.y*u.y;
                tu02 += t.x*u.z;
                tu30 += t.w*u.x;
                tu21 += t.z*u.y;
                tu12 += t.y*u.z;
                tu03 += t.x*u.w;
            }
            tuv000 += tu00*v.x;
            tuv100 += tu10*v.x;
            tuv010 += tu01*v.x;
            tuv001 += tu00*v.y;
            tuv200 += tu20*v.x;
            tuv020 += tu02*v.x;
            tuv002 += tu00*v.z;
            tuv110 += tu11*v.x;
            tuv101 += tu10*v.y;
            tuv011 += tu01*v.y;
            tuv300 += tu30*v.x;
            tuv030 += tu03*v.x;
            tuv003 += tu00*v.w;
            tuv210 += tu21*v.x;
            tuv201 += tu20*v.y;
            tuv120 += tu12*v.x;
            tuv021 += tu02*v.y;
            tuv102 += tu10*v.z;
            tuv012 += tu01*v.z;
            tuv111 += tu11*v.y;
        }
        cAmoebaSim.pPhi[20*m] = tuv000;
        cAmoebaSim.pPhi[20*m+1] = tuv100;
        cAmoebaSim.pPhi[20*m+2] = tuv010;
        cAmoebaSim.pPhi[20*m+3] = tuv001;
        cAmoebaSim.pPhi[20*m+4] = tuv200;
        cAmoebaSim.pPhi[20*m+5] = tuv020;
        cAmoebaSim.pPhi[20*m+6] = tuv002;
        cAmoebaSim.pPhi[20*m+7] = tuv110;
        cAmoebaSim.pPhi[20*m+8] = tuv101;
        cAmoebaSim.pPhi[20*m+9] = tuv011;
        cAmoebaSim.pPhi[20*m+10] = tuv300;
        cAmoebaSim.pPhi[20*m+11] = tuv030;
        cAmoebaSim.pPhi[20*m+12] = tuv003;
        cAmoebaSim.pPhi[20*m+13] = tuv210;
        cAmoebaSim.pPhi[20*m+14] = tuv201;
        cAmoebaSim.pPhi[20*m+15] = tuv120;
        cAmoebaSim.pPhi[20*m+16] = tuv021;
        cAmoebaSim.pPhi[20*m+17] = tuv102;
        cAmoebaSim.pPhi[20*m+18] = tuv012;
        cAmoebaSim.pPhi[20*m+19] = tuv111;
    }
}

__global__
#if (__CUDA_ARCH__ >= 200)
__launch_bounds__(1024, 1)
#elif (__CUDA_ARCH__ >= 120)
__launch_bounds__(512, 1)
#else
__launch_bounds__(256, 1)
#endif
void kComputeInducedPotentialFromGrid_kernel()
{
    // extract the induced dipole field at each site

    for (int m = blockIdx.x*blockDim.x+threadIdx.x; m < cSim.atoms; m += blockDim.x*gridDim.x) {
        int4 grid = cAmoebaSim.pIgrid[m];
        float tuv100_1 = 0.0f;
        float tuv010_1 = 0.0f;
        float tuv001_1 = 0.0f;
        float tuv200_1 = 0.0f;
        float tuv020_1 = 0.0f;
        float tuv002_1 = 0.0f;
        float tuv110_1 = 0.0f;
        float tuv101_1 = 0.0f;
        float tuv011_1 = 0.0f;
        float tuv100_2 = 0.0f;
        float tuv010_2 = 0.0f;
        float tuv001_2 = 0.0f;
        float tuv200_2 = 0.0f;
        float tuv020_2 = 0.0f;
        float tuv002_2 = 0.0f;
        float tuv110_2 = 0.0f;
        float tuv101_2 = 0.0f;
        float tuv011_2 = 0.0f;
        float tuv000 = 0.0f;
        float tuv001 = 0.0f;
        float tuv010 = 0.0f;
        float tuv100 = 0.0f;
        float tuv200 = 0.0f;
        float tuv020 = 0.0f;
        float tuv002 = 0.0f;
        float tuv110 = 0.0f;
        float tuv101 = 0.0f;
        float tuv011 = 0.0f;
        float tuv300 = 0.0f;
        float tuv030 = 0.0f;
        float tuv003 = 0.0f;
        float tuv210 = 0.0f;
        float tuv201 = 0.0f;
        float tuv120 = 0.0f;
        float tuv021 = 0.0f;
        float tuv102 = 0.0f;
        float tuv012 = 0.0f;
        float tuv111 = 0.0f;
        for (int it3 = 0; it3 < AMOEBA_PME_ORDER; it3++) {
            int k = grid.z+it3-(grid.z+it3 >= cSim.pmeGridSize.z ? cSim.pmeGridSize.z : 0);
            float4 v = cAmoebaSim.pThetai3[m*AMOEBA_PME_ORDER+it3];
            float tu00_1 = 0.0f;
            float tu01_1 = 0.0f;
            float tu10_1 = 0.0f;
            float tu20_1 = 0.0f;
            float tu11_1 = 0.0f;
            float tu02_1 = 0.0f;
            float tu00_2 = 0.0f;
            float tu01_2 = 0.0f;
            float tu10_2 = 0.0f;
            float tu20_2 = 0.0f;
            float tu11_2 = 0.0f;
            float tu02_2 = 0.0f;
            float tu00 = 0.0f;
            float tu10 = 0.0f;
            float tu01 = 0.0f;
            float tu20 = 0.0f;
            float tu11 = 0.0f;
            float tu02 = 0.0f;
            float tu30 = 0.0f;
            float tu21 = 0.0f;
            float tu12 = 0.0f;
            float tu03 = 0.0f;
            for (int it2 = 0; it2 < AMOEBA_PME_ORDER; it2++) {
                int j = grid.y+it2-(grid.y+it2 >= cSim.pmeGridSize.y ? cSim.pmeGridSize.y : 0);
                float4 u = cAmoebaSim.pThetai2[m*AMOEBA_PME_ORDER+it2];
                float t0_1 = 0.0f;
                float t1_1 = 0.0f;
                float t2_1 = 0.0f;
                float t0_2 = 0.0f;
                float t1_2 = 0.0f;
                float t2_2 = 0.0f;
                float t3 = 0.0f;
                for (int it1 = 0; it1 < AMOEBA_PME_ORDER; it1++) {
                    int i = grid.x+it1-(grid.x+it1 >= cSim.pmeGridSize.x ? cSim.pmeGridSize.x : 0);
                    int gridIndex = i*cSim.pmeGridSize.y*cSim.pmeGridSize.z + j*cSim.pmeGridSize.z + k;
                    cufftComplex tq = cSim.pPmeGrid[gridIndex];
                    float4 tadd = cAmoebaSim.pThetai1[m*AMOEBA_PME_ORDER+it1];
                    t0_1 += tq.x*tadd.x;
                    t1_1 += tq.x*tadd.y;
                    t2_1 += tq.x*tadd.z;
                    t0_2 += tq.y*tadd.x;
                    t1_2 += tq.y*tadd.y;
                    t2_2 += tq.y*tadd.z;
                    t3 += (tq.x+tq.x)*tadd.w;
                }
                tu00_1 += t0_1*u.x;
                tu10_1 += t1_1*u.x;
                tu01_1 += t0_1*u.y;
                tu20_1 += t2_1*u.x;
                tu11_1 += t1_1*u.y;
                tu02_1 += t0_1*u.z;
                tu00_2 += t0_2*u.x;
                tu10_2 += t1_2*u.x;
                tu01_2 += t0_2*u.y;
                tu20_2 += t2_2*u.x;
                tu11_2 += t1_2*u.y;
                tu02_2 += t0_2*u.z;
                float t0 = t0_1 + t0_2;
                float t1 = t1_1 + t1_2;
                float t2 = t2_1 + t2_2;
                tu00 += t0*u.x;
                tu10 += t1*u.x;
                tu01 += t0*u.y;
                tu20 += t2*u.x;
                tu11 += t1*u.y;
                tu02 += t0*u.z;
                tu30 += t3*u.x;
                tu21 += t2*u.y;
                tu12 += t1*u.z;
                tu03 += t0*u.w;
            }
            tuv100_1 += tu10_1*v.x;
            tuv010_1 += tu01_1*v.x;
            tuv001_1 += tu00_1*v.y;
            tuv200_1 += tu20_1*v.x;
            tuv020_1 += tu02_1*v.x;
            tuv002_1 += tu00_1*v.z;
            tuv110_1 += tu11_1*v.x;
            tuv101_1 += tu10_1*v.y;
            tuv011_1 += tu01_1*v.y;
            tuv100_2 += tu10_2*v.x;
            tuv010_2 += tu01_2*v.x;
            tuv001_2 += tu00_2*v.y;
            tuv200_2 += tu20_2*v.x;
            tuv020_2 += tu02_2*v.x;
            tuv002_2 += tu00_2*v.z;
            tuv110_2 += tu11_2*v.x;
            tuv101_2 += tu10_2*v.y;
            tuv011_2 += tu01_2*v.y;
            tuv000 += tu00*v.x;
            tuv100 += tu10*v.x;
            tuv010 += tu01*v.x;
            tuv001 += tu00*v.y;
            tuv200 += tu20*v.x;
            tuv020 += tu02*v.x;
            tuv002 += tu00*v.z;
            tuv110 += tu11*v.x;
            tuv101 += tu10*v.y;
            tuv011 += tu01*v.y;
            tuv300 += tu30*v.x;
            tuv030 += tu03*v.x;
            tuv003 += tu00*v.w;
            tuv210 += tu21*v.x;
            tuv201 += tu20*v.y;
            tuv120 += tu12*v.x;
            tuv021 += tu02*v.y;
            tuv102 += tu10*v.z;
            tuv012 += tu01*v.z;
            tuv111 += tu11*v.y;
        }
        cAmoebaSim.pPhid[20*m+1] = tuv100_1;
        cAmoebaSim.pPhid[20*m+2] = tuv010_1;
        cAmoebaSim.pPhid[20*m+3] = tuv001_1;
        cAmoebaSim.pPhid[20*m+4] = tuv200_1;
        cAmoebaSim.pPhid[20*m+5] = tuv020_1;
        cAmoebaSim.pPhid[20*m+6] = tuv002_1;
        cAmoebaSim.pPhid[20*m+7] = tuv110_1;
        cAmoebaSim.pPhid[20*m+8] = tuv101_1;
        cAmoebaSim.pPhid[20*m+9] = tuv011_1;
        cAmoebaSim.pPhip[20*m+1] = tuv100_2;
        cAmoebaSim.pPhip[20*m+2] = tuv010_2;
        cAmoebaSim.pPhip[20*m+3] = tuv001_2;
        cAmoebaSim.pPhip[20*m+4] = tuv200_2;
        cAmoebaSim.pPhip[20*m+5] = tuv020_2;
        cAmoebaSim.pPhip[20*m+6] = tuv002_2;
        cAmoebaSim.pPhip[20*m+7] = tuv110_2;
        cAmoebaSim.pPhip[20*m+8] = tuv101_2;
        cAmoebaSim.pPhip[20*m+9] = tuv011_2;
        cAmoebaSim.pPhidp[20*m] = tuv000;
        cAmoebaSim.pPhidp[20*m+1] = tuv100;
        cAmoebaSim.pPhidp[20*m+2] = tuv010;
        cAmoebaSim.pPhidp[20*m+3] = tuv001;
        cAmoebaSim.pPhidp[20*m+4] = tuv200;
        cAmoebaSim.pPhidp[20*m+5] = tuv020;
        cAmoebaSim.pPhidp[20*m+6] = tuv002;
        cAmoebaSim.pPhidp[20*m+7] = tuv110;
        cAmoebaSim.pPhidp[20*m+8] = tuv101;
        cAmoebaSim.pPhidp[20*m+9] = tuv011;
        cAmoebaSim.pPhidp[20*m+10] = tuv300;
        cAmoebaSim.pPhidp[20*m+11] = tuv030;
        cAmoebaSim.pPhidp[20*m+12] = tuv003;
        cAmoebaSim.pPhidp[20*m+13] = tuv210;
        cAmoebaSim.pPhidp[20*m+14] = tuv201;
        cAmoebaSim.pPhidp[20*m+15] = tuv120;
        cAmoebaSim.pPhidp[20*m+16] = tuv021;
        cAmoebaSim.pPhidp[20*m+17] = tuv102;
        cAmoebaSim.pPhidp[20*m+18] = tuv012;
        cAmoebaSim.pPhidp[20*m+19] = tuv111;
    }
}
