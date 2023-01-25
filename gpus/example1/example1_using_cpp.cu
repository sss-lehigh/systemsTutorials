#include <vector>
#include <cstdlib>
#include <algorithm>
#include <execution>
#include <iostream>
#include <chrono>
#include <tbb/parallel_for.h>
#include <thrust/device_vector.h>
#include <thrust/host_vector.h>
#include <thrust/transform.h>

template<typename T>
using vector = thrust::host_vector<T>;

// kernel function to perform vector c = alpha * a + b
// size is the size of the vectors
// __restrict__ tells the compiler a, b, and c will not
// alias to each other (as in a != b, b != c, and a != c
__global__ void saxpy(const float alpha, const float* __restrict__ a, const float* __restrict__ b, float* __restrict__ c, int size) {

    // each block handles 1024 elements
    // each block has 64 threads
    // each thread in a block handles 4 of those elements
    // we iterate 4 times to handle the 1024 elements
    constexpr int elements_per_thread = 4;
    
    // threadIdx.x is the location within the grid
    // blockIdx.x is the location of the block
    // blockDim.x is the dimension of the block (threads per block)
    // we know blockDim.x = 64 so we substitute 64 in
    int tidx = threadIdx.x; 
    
    // we will block the vector addition with 4 elements per each thread
   
    int bidx = blockIdx.x;

    const float* a_block = a + bidx * 1024;
    const float* b_block = b + bidx * 1024;
    float* c_block = c + bidx * 1024;

    // if we know we are in bounds of the vector or if the vector size is evenly divisible by 1024
    if(bidx < size / 1024 || (size + 1023) / 1024 == size / 1024) {

        // we process 256 floating point calculations per loop
        // float 512 floats loaded and 256 stored
        #pragma unroll
        for(int i = 0; i < 1024 / 64 / elements_per_thread; ++i) {
            float4 reg_a = *(reinterpret_cast<const float4*>(a_block) + tidx + i * 64);
            float4 reg_b = *(reinterpret_cast<const float4*>(b_block) + tidx + i * 64);
            
            reg_b.w += alpha * reg_a.w;
            reg_b.x += alpha * reg_a.x;
            reg_b.y += alpha * reg_a.y;
            reg_b.z += alpha * reg_a.z;

            *(reinterpret_cast<float4*>(c_block) + tidx + i * 64) = reg_b;
        }
    } else {
        #pragma unroll
        for(int i = 0; i < 1024 / 64 / elements_per_thread; ++i) {

            // if the loads and stores are all in bounds proceed as normal
            if(bidx + tidx + i * 256 + 3 < size) {
                float4 reg_a = *(reinterpret_cast<const float4*>(a_block) + tidx + i * 64);
                float4 reg_b = *(reinterpret_cast<const float4*>(b_block) + tidx + i * 64);
                
                reg_b.w += alpha * reg_a.w;
                reg_b.x += alpha * reg_a.x;
                reg_b.y += alpha * reg_a.y;
                reg_b.z += alpha * reg_a.z;

                *(reinterpret_cast<float4*>(c_block) + tidx + i * 64) = reg_b;
            } else if(bidx + tidx + i * 256 < size) {

                // perform each individually

                float reg_a;
                float reg_b;

                for(int j = 0; j < 4; ++j) {
                    if(j + tidx + i * 256 < size) {
                        reg_a = a_block[j + tidx + i * 256];
                        reg_b = b_block[j + tidx + i * 256];
                        
                        reg_b += alpha * reg_a;

                        c_block[j + tidx + i * 256] = reg_b;
                    }
                }
            }

        }
    }
}

int main() {

    // Lets add and scale two vectors together:
    // c = alpha * a + b
    //

    const int size = 1000000;


    // we will create size element vectors
    vector<float> a(size, 0);
    vector<float> b(size, 0);
    vector<float> c(size, 0);

    // std::tranform reads from the range a.cbegin() to a.cend()
    // and will write the result out iteratively to a.begin()
    // it uses the function std::rand to output the result
    std::transform(a.cbegin(), a.cend(), a.begin(), [](auto) { return static_cast<float>(rand()) / RAND_MAX; });
    std::transform(b.cbegin(), b.cend(), b.begin(), [](auto) { return static_cast<float>(rand()) / RAND_MAX; });

    // we set alpha to 1
    float alpha = 1.0f;

    auto start = std::chrono::high_resolution_clock::now();
   
    // we add together using a lambda from a.cbegin() to a.cend()
    // and b.cbegin() until we iterate through a and output to c
    // we use the lambda to capture alpha and add the two numbers
    std::transform(std::execution::seq, a.begin(), a.end(), b.begin(), c.begin(), [alpha](const auto& a, const auto& b) {
        return alpha * a + b;
    });
    
    auto end = std::chrono::high_resolution_clock::now();
    
    double seq_time = std::chrono::duration<double>(end - start).count();

    vector<float> c2(size, 0);

    start = std::chrono::high_resolution_clock::now();

    // lets compare to a parallel execution that can be parallelized or vectorized
    // in any way the compiler desires
    std::transform(std::execution::par_unseq, a.begin(), a.end(), b.begin(), c2.begin(), [alpha](const auto& a, const auto& b) {
        return alpha * a + b;
    });
    
    end = std::chrono::high_resolution_clock::now();

    double par_time = std::chrono::duration<double>(end - start).count();

    bool fail = false;
    for(int i = 0; i < size; ++i) {
        if(std::abs(c[i] - c2[i]) > std::abs(c[i] * 1e-5)) {
            std::cerr << "Error cpp transform: c[" << i << "] do not match " << c[i] << " != " << c2[i] << std::endl;
            std::cerr << "Computed: " << a[i] << " + " << b[i] << std::endl;
            fail = true; 
        }
    }

    if(fail) return 1;

    // lets try tbb parallel for
    //

    start = std::chrono::high_resolution_clock::now();
    tbb::parallel_for(tbb::blocked_range<int>(0, size), 
                      [&](tbb::blocked_range<int> r) {
        for(int i = r.begin(); i < r.end(); ++i) {
            c2[i] = alpha * a[i] + b[i];
        }  
    });
    end = std::chrono::high_resolution_clock::now();
    
    double tbb_time = std::chrono::duration<double>(end - start).count();

    for(int i = 0; i < size; ++i) {
        if(std::abs(c[i] - c2[i]) > std::abs(c[i] * 1e-5)) {
            std::cerr << "Error tbb parallel for: c[" << i << "] do not match " << c[i] << " != " << c2[i] << std::endl;
            std::cerr << "Computed: " << a[i] << " + " << b[i] << std::endl;
            fail = true; 
        }
    }

    thrust::device_vector<float> c_kern(size, 0);

    start = std::chrono::high_resolution_clock::now();
    
    thrust::device_vector<float> a_kern(a.begin(), a.end());
    thrust::device_vector<float> b_kern(b.begin(), b.end());

    thrust::transform(a_kern.begin(), a_kern.end(), b_kern.begin(), c_kern.begin(), [=] __host__ __device__ (const float& a, const float& b) {
        return alpha * a + b;        
    });

    thrust::copy(c2.begin(), c2.end(), c_kern.begin());
    
    end = std::chrono::high_resolution_clock::now();
    
    double thrust_time = std::chrono::duration<double>(end - start).count();

    for(int i = 0; i < size; ++i) {
        if(std::abs(c[i] - c2[i]) > std::abs(c[i] * 1e-5)) {
            std::cerr << "Error tbb parallel for: c[" << i << "] do not match " << c[i] << " != " << c2[i] << std::endl;
            std::cerr << "Computed: " << a[i] << " + " << b[i] << std::endl;
            fail = true; 
        }
    }

    if(fail) return 1;

    float* c_kern2;
    float* a_kern2;
    float* b_kern2;

    // malloc similar to c malloc but takes
    // pointer to where you write what you allocated
    cudaError_t cudaError = cudaMalloc(&a_kern2, sizeof(float) * size);
    if(cudaError != cudaSuccess) {
        std::cerr << "cuda failure" << std::endl;
        return 2;
    }

    cudaError = cudaMalloc(&b_kern2, sizeof(float) * size);
    if(cudaError != cudaSuccess) {
        std::cerr << "cuda failure" << std::endl;
        return 2;
    }

    cudaError = cudaMalloc(&c_kern2, sizeof(float) * size);
    if(cudaError != cudaSuccess) {
        std::cerr << "cuda failure" << std::endl;
        return 2;
    }


    start = std::chrono::high_resolution_clock::now();
  
    // memory copies to gpu similar to C memcpy API plus where to where you are copying 
    cudaError = cudaMemcpy(a_kern2, a.data(), sizeof(float) * size, cudaMemcpyHostToDevice);
    if(cudaError != cudaSuccess) {
        std::cerr << "cuda failure" << std::endl;
        return 2;
    }

    cudaError = cudaMemcpy(b_kern2, b.data(), sizeof(float) * size, cudaMemcpyHostToDevice);
    if(cudaError != cudaSuccess) {
        std::cerr << "cuda failure" << std::endl;
        return 2;
    }

    // asynchronous launch of GPU with x blocks and y threads per block
    saxpy<<<(size + 1023) / 1024, 64>>>(alpha, a_kern2, b_kern2, c_kern2, size);
   
    cudaError = cudaDeviceSynchronize(); // synchronize with GPU
    if(cudaError != cudaSuccess) {
        std::cerr << "cuda failure" << std::endl;
        return 2;
    }

    cudaError = cudaMemcpy(c2.data(), c_kern2, sizeof(float) * size, cudaMemcpyDeviceToHost);
    if(cudaError != cudaSuccess) {
        std::cerr << "cuda failure" << std::endl;
        return 2;
    }

    end = std::chrono::high_resolution_clock::now();
    
    double cuda_time = std::chrono::duration<double>(end - start).count();

    cudaError = cudaFree(a_kern2);
    if(cudaError != cudaSuccess) {
        std::cerr << "cuda failure" << std::endl;
        return 2;
    }
    cudaError = cudaFree(b_kern2);
    if(cudaError != cudaSuccess) {
        std::cerr << "cuda failure" << std::endl;
        return 2;
    }
    cudaError = cudaFree(c_kern2);
    if(cudaError != cudaSuccess) {
        std::cerr << "cuda failure" << std::endl;
        return 2;
    }

    for(int i = 0; i < size; ++i) {
        if(std::abs(c[i] - c2[i]) > std::abs(c[i] * 1e-5)) {
            std::cerr << "Error cuda parallel for: c[" << i << "] do not match " << c[i] << " != " << c2[i] << std::endl;
            std::cerr << "Computed: " << a[i] << " + " << b[i] << std::endl;
            fail = true; 
        }
    }

    std::cout << "Duration of parallel cpp version (ms):\t\t" << par_time * 1e3 << std::endl;
    std::cout << "Duration of parallel tbb version (ms):\t\t" << tbb_time * 1e3 << std::endl;
    std::cout << "Duration of parallel thrust version (ms):\t" << thrust_time * 1e3 << std::endl;
    std::cout << "Duration of parallel cuda version (ms):\t\t" << cuda_time * 1e3 << std::endl;
    std::cout << "Duration of sequential version (ms):\t\t" << seq_time * 1e3 << std::endl;
    auto times = std::vector<double>{tbb_time, par_time, thrust_time, cuda_time};
    double best = *std::min_element(times.begin(), times.end());
    std::cout << "Speedup of best:\t\t\t\t" << seq_time / best << std::endl;
    return 0;
}
