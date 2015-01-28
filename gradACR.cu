// nvcc -m64 -shared -arch=sm_20 -o libgradACR.so  -Xcompiler -fPIC gradACR.cu

#include <stdio.h>

extern "C" {
#include "gradACR.h"
}
#include <cuda.h>

__global__ void test(void)
{
    //printf("Hello from thread %d block %d\n", threadIdx.x, blockIdx.x);
    //for(int i=0; i<1000; i++) {
    //	int a = 1;
    // 	for(int j=1;j<10000;j++) {
    //		int b = a*10;
    //	}
    //}
}


__device__ void matrixmul(double pose[3][3], double output_coords[3],double template_coords[3]){
	int i, j;
	for(i=0;i<3;i++){
		template_coords[i]=0;
		for(j=0;j<3;j++) {
			template_coords[i] += pose[i][j]*output_coords[j];
		}
	}
}



__device__ double getTemplateValue(int tdim, int bsize, int bid, double *_template, double template_x, double template_y) 
{

	double res=0;
	double template_x_size = tdim + 1; 
	double template_y_size = tdim + 1; 
	int output_x =  floor(template_x + template_x_size/2);
	int output_y = floor(template_y + template_y_size/2);

	if (output_x < 1 || output_x > tdim || output_y < 1 || output_y > tdim) {
		res = 0.0;
	}
	else {
		res = _template[bid*tdim*tdim + tdim*output_x + output_y];
	}
	return res;
}


 __device__ inline void MyAtomicAdd_8(double *address, double value)
 {
   unsigned long long oldval, newval, readback; 
 
   oldval = __double_as_longlong(*address);
   newval = __double_as_longlong(__longlong_as_double(oldval) + value);
   while ((readback=atomicCAS((unsigned long long *)address, oldval, newval)) != oldval)
     {
      oldval = readback;
      newval = __double_as_longlong(__longlong_as_double(oldval) + value);
     }
 }


__global__ void getgradient(int imwidth, int tdim, int bsize, double *cuda_output, double *cuda_pose, double *cuda_template, double *cuda_gradOutput, double *cuda_gradTemplate, double *cuda_gradPose)
{
	int i;

	//printf("block: (%d %d %d) || grid: (%d %d %d)\n", threadIdx.x, threadIdx.y, threadIdx.z, blockIdx.x, blockIdx.y, blockIdx.z);
	unsigned int bid = threadIdx.z; //index of image in batch
	unsigned int output_x = blockIdx.x;
	unsigned int output_y = blockIdx.y;


	double output_coords[3];
	output_coords[0]=output_x; output_coords[1]=output_y; output_coords[2]=1;

	double template_coords[3];
	double pose[3][3];
	for(i=0;i<9;i++) {
		pose[int(i/3)][i%3] = cuda_pose[bid*9 + i];
	}
	matrixmul(pose, output_coords, template_coords);

	double template_x = template_coords[0] - 0.5;
	double template_y = template_coords[1] - 0.5;

	
	float x_high_coeff = fmod(template_x , 1); 
	float y_high_coeff = fmod(template_y ,1); 	
	
	double x_low_coeff = -x_high_coeff + 1;
	double y_low_coeff = -y_high_coeff + 1;

	int x_low = floor(template_x);
	int x_high = x_low + 1;
	int y_low = floor(template_y);
	int y_high = y_low + 1;

	///////////// Pose Gradient Initial /////////////
	double template_val_xhigh_yhigh = getTemplateValue(bsize, tdim, bid, cuda_template, x_high, y_high);
	double template_val_xhigh_ylow = getTemplateValue(bsize, tdim, bid, cuda_template, x_high, y_low);
	double template_val_xlow_ylow = getTemplateValue(bsize, tdim, bid, cuda_template, x_low, y_low);
	double template_val_xlow_yhigh = getTemplateValue(bsize, tdim, bid, cuda_template, x_low, y_high);

	double pose_1_1, pose_1_2, pose_1_3, pose_2_1, pose_2_2, pose_2_3;
	pose_1_1 = pose[0][0]; pose_1_2 = pose[0][1]; pose_1_3 = pose[0][2];
	pose_2_1 = pose[1][0]; pose_2_2 = pose[1][1]; pose_2_3 = pose[1][2];

	double cache1,cache2, cache3,cache4, cache5, cache6, cache7;
	double cache8, cache9, cache10, cache11, cache12, cache13, cache14;

	cache1 = pose_2_3 - y_low + pose_2_1*output_x + pose_2_2*output_y;
	cache2 = pose_2_3 - y_high + pose_2_1*output_x + pose_2_2*output_y;
	cache3 = pose_1_3 - x_low + pose_1_1*output_x + pose_1_2*output_y;
	cache4 = pose_1_3 - x_high + pose_1_1*output_x + pose_1_2*output_y;

	cache5 = template_val_xhigh_yhigh * cache3;
	cache6 = template_val_xlow_yhigh * cache4;
	cache7 = template_val_xhigh_ylow * cache3;
	cache8 = template_val_xlow_ylow * cache4;

	double cache_gradOutput_outputx_outputy = cuda_gradOutput[bid*imwidth*imwidth + imwidth*output_x + output_y];

	cache9 = cache_gradOutput_outputx_outputy * (cache5-cache6);
	cache10 = cache7 - cache8;

	cache11 = (template_val_xhigh_ylow - template_val_xlow_ylow)*cache2;
	cache12 = cache_gradOutput_outputx_outputy*( (template_val_xhigh_yhigh - template_val_xlow_yhigh)*cache1 );

	cache13 = cache12 - cache11;
	cache14 = cache9 - cache10;
	
	///////////// Template Gradient Initial /////////
	double x_vec[2], y_vec[2];
	x_vec[0]=x_low_coeff; x_vec[1]=x_high_coeff;
	y_vec[0]=y_low_coeff; y_vec[1]=y_high_coeff;

	double dOutdPose[2][2]; //outer-product
	dOutdPose[0][0] = x_vec[0]*y_vec[0];
	dOutdPose[0][1] = x_vec[0]*y_vec[1];
	dOutdPose[1][0] = x_vec[1]*y_vec[0];
	dOutdPose[1][1] = x_vec[1]*y_vec[1];

	////////////////////// accumulate gradient ////////////////
	///////////// using atomics to avoid race condition ///////
	if (x_low >= 1 && x_low <= tdim && y_low >= 1 && y_low <= tdim) 
		MyAtomicAdd_8(&(cuda_gradTemplate[bid*tdim*tdim + tdim*x_low + y_low]), dOutdPose[0][0]);

	if (x_low >= 1 && x_low <= tdim && y_high >= 1 && y_high <= tdim) 
		MyAtomicAdd_8(&(cuda_gradTemplate[bid*tdim*tdim + tdim*x_low + y_high]), dOutdPose[0][1]);
	
	if (x_high >= 1 && x_high <= tdim && y_low >= 1 && y_low <= tdim) 
		MyAtomicAdd_8(&(cuda_gradTemplate[bid*tdim*tdim + tdim*x_high + y_low]), dOutdPose[1][0]);
	
	if (x_high >= 1 && x_high <= tdim && y_high >= 1 && y_high <= tdim) 
		MyAtomicAdd_8(&(cuda_gradTemplate[bid*tdim*tdim + tdim*x_high + y_high]), dOutdPose[1][1]);
	
	MyAtomicAdd_8(&(cuda_gradPose[bid*9]), cache13*output_x);
	MyAtomicAdd_8(&(cuda_gradPose[bid*9 + 1]), cache13*output_y);
	MyAtomicAdd_8(&(cuda_gradPose[bid*9 + 2]), cache12 - cache11);
	MyAtomicAdd_8(&(cuda_gradPose[bid*9 + 3]), cache14 * output_x);
	MyAtomicAdd_8(&(cuda_gradPose[bid*9 + 4]), cache14 * output_y);
	MyAtomicAdd_8(&(cuda_gradPose[bid*9 + 5]), (cache_gradOutput_outputx_outputy*cache5)-cache6-cache7+cache8);	
}		


extern "C" void get_gradACR_gradient(int imwidth, int tdim, int bsize, double *cuda_output, double *cuda_pose, 
						double *cuda_template, double *cuda_gradOutput, double *cuda_gradTemplate, double *cuda_gradPose)
{	
	//setup GPU grid and block structure
	//dim3 grid; grid.x=32; grid.y = 32;
	dim3 grid; grid.x=3; grid.y = 3;

	//dim3 block; block.x=1; block.y=1; block.z=bsize;
	dim3 block; block.x=1; block.y=1; block.z=2;

    getgradient<<<grid,block>>>(imwidth, tdim,  bsize, cuda_output, cuda_pose, cuda_template, cuda_gradOutput, cuda_gradTemplate, cuda_gradPose);
    printf("CUDA status: %d\n", cudaDeviceSynchronize());
}