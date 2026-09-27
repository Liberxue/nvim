// Minimal declarations so clangd can parse CUDA without a toolkit installed.
//
// This machine has no CUDA toolkit and cannot have one: macOS dropped NVIDIA
// support after 10.13. Without the real headers clangd flags __global__,
// blockIdx and every runtime call as undeclared, which buries any genuine
// diagnostic. These declarations are for the editor only -- nothing here is
// compiled, and nvcc on a real machine never sees this file.
//
// Deliberately incomplete: it covers the identifiers that appear in ordinary
// kernel code, not the full API. Add to it when something legitimate gets
// flagged.
#pragma once

#ifdef __CUDA_STUB__

// These map to the attributes clang actually understands in CUDA mode. Defining
// them to nothing makes every <<<>>> launch report "kernel call to non-global
// function", because the attribute is what marks a kernel.
#define __global__ __attribute__((global))
#define __device__ __attribute__((device))
#define __host__ __attribute__((host))
#define __shared__ __attribute__((shared))
#define __constant__ __attribute__((constant))
#define __managed__ __attribute__((managed))
#define __restrict__
#define __forceinline__ inline
#define __launch_bounds__(...)

struct uint3 {
  unsigned x, y, z;
};
struct dim3 {
  unsigned x, y, z;
  __host__ __device__ dim3(unsigned x = 1, unsigned y = 1, unsigned z = 1);
};

// Device-side, or clang reports "reference to __host__ variable in __global__
// function" on every kernel that reads them.
extern __device__ uint3 threadIdx;
extern __device__ uint3 blockIdx;
extern __device__ dim3 blockDim;
extern __device__ dim3 gridDim;
extern __device__ int warpSize;

__device__ void __syncthreads();
__device__ void __threadfence();
__device__ void __threadfence_block();
__device__ unsigned __ballot_sync(unsigned mask, int predicate);
__device__ int __shfl_sync(unsigned mask, int var, int srcLane, int width = 32);
__device__ int __shfl_down_sync(unsigned mask, int var, unsigned delta, int width = 32);
__device__ int __shfl_up_sync(unsigned mask, int var, unsigned delta, int width = 32);
__device__ int __shfl_xor_sync(unsigned mask, int var, int laneMask, int width = 32);
__device__ int atomicAdd(int* address, int val);
__device__ float atomicAdd(float* address, float val);
__device__ unsigned atomicAdd(unsigned* address, unsigned val);
__device__ int atomicMax(int* address, int val);
__device__ int atomicMin(int* address, int val);
__device__ int atomicExch(int* address, int val);
__device__ int atomicCAS(int* address, int compare, int val);

typedef enum cudaError { cudaSuccess = 0 } cudaError_t;
typedef enum cudaMemcpyKind {
  cudaMemcpyHostToHost = 0,
  cudaMemcpyHostToDevice = 1,
  cudaMemcpyDeviceToHost = 2,
  cudaMemcpyDeviceToDevice = 3,
  cudaMemcpyDefault = 4
} cudaMemcpyKind;
typedef struct CUstream_st* cudaStream_t;
typedef struct CUevent_st* cudaEvent_t;

// Templated like the real one, which is what lets cudaMalloc(&floatPtr, n)
// compile without a void** cast.
template <typename T>
cudaError_t cudaMalloc(T** devPtr, unsigned long size);
template <typename T>
cudaError_t cudaMallocManaged(T** devPtr, unsigned long size, unsigned flags = 1);
cudaError_t cudaFree(void* devPtr);
cudaError_t cudaMemcpy(void* dst, const void* src, unsigned long count, cudaMemcpyKind kind);
cudaError_t cudaMemcpyAsync(void* dst, const void* src, unsigned long count, cudaMemcpyKind kind, cudaStream_t stream = 0);
cudaError_t cudaMemset(void* devPtr, int value, unsigned long count);
cudaError_t cudaDeviceSynchronize();
cudaError_t cudaStreamCreate(cudaStream_t* stream);
cudaError_t cudaStreamDestroy(cudaStream_t stream);
cudaError_t cudaStreamSynchronize(cudaStream_t stream);
cudaError_t cudaEventCreate(cudaEvent_t* event);
cudaError_t cudaEventRecord(cudaEvent_t event, cudaStream_t stream = 0);
cudaError_t cudaEventSynchronize(cudaEvent_t event);
cudaError_t cudaEventElapsedTime(float* ms, cudaEvent_t start, cudaEvent_t end);
cudaError_t cudaGetLastError();
const char* cudaGetErrorString(cudaError_t error);

// clang lowers <<<grid, block>>> into these, so they have to exist even though
// no hand-written code calls them.
cudaError_t cudaConfigureCall(dim3 gridDim, dim3 blockDim, unsigned long sharedMem = 0, cudaStream_t stream = 0);
unsigned __cudaPushCallConfiguration(dim3 gridDim, dim3 blockDim, unsigned long sharedMem = 0, cudaStream_t stream = 0);
cudaError_t cudaSetupArgument(const void* arg, unsigned long size, unsigned long offset);
cudaError_t cudaLaunch(const void* func);

#endif // __CUDA_STUB__
