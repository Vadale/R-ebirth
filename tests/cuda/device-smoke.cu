// D-050 toolchain/driver/device check. No relm model or benchmark claim.
#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>

static void check(cudaError_t code, const char *operation) {
    if (code != cudaSuccess) {
        std::fprintf(stderr, "%s: %s\n", operation, cudaGetErrorString(code));
        std::exit(1);
    }
}
__global__ void transform(float *values) {
    const int i = threadIdx.x;
    values[i] = 3.0f * i + 1.0f;
}
int main() {
    int count = 0, runtime = 0, driver = 0;
    check(cudaGetDeviceCount(&count), "device count");
    if (count < 1) return 2;
    check(cudaSetDevice(0), "select device");
    cudaDeviceProp prop{};
    check(cudaGetDeviceProperties(&prop, 0), "device properties");
    check(cudaRuntimeGetVersion(&runtime), "runtime version");
    check(cudaDriverGetVersion(&driver), "driver version");
    float *device = nullptr, host[32];
    check(cudaMalloc(&device, sizeof(host)), "device allocation");
    transform<<<1, 32>>>(device);
    check(cudaGetLastError(), "kernel launch");
    check(cudaDeviceSynchronize(), "device synchronization");
    check(cudaMemcpy(host, device, sizeof(host), cudaMemcpyDeviceToHost), "read device");
    check(cudaFree(device), "device release");
    for (int i = 0; i < 32; ++i) if (host[i] != 3.0f * i + 1.0f) return 3;
    std::printf("CUDA_DEVICE_PASS device=%s capability=%d.%d runtime=%d driver=%d values=32\n",
                prop.name, prop.major, prop.minor, runtime, driver);
}
