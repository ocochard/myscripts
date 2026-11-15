#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1e3+t.tv_nsec/1e6;}
int main(int argc,char**argv){
	int f=open("/sys/kernel/debug/dri/1/amdgpu_regs",O_RDONLY);
	uint32_t r[]={0x66404,0x66470,0x66434,0x66474,0x66478,0x66480,0x66700,0x62058};
	uint32_t v[8],p[8]={~0u,~0u,~0u,~0u,~0u,~0u,~0u,~0u};
	double t0=now(),dur=atof(argv[1])*1000; long n=0;
	while(now()-t0<dur){
		for(int i=0;i<8;i++) pread(f,&v[i],4,r[i]);
		n++;
		if(v[0]!=p[0]||v[5]!=p[5]||v[6]!=p[6]||v[7]!=p[7]||((v[1]^p[1])&0x20)){
			printf("%9.3f ms tar 0x%x st 0x%x raw 0x%x txfl %u rxfl %u abrt 0x%x phy 0x%x boot 0x%x\n",now()-t0,v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7]);
			for(int i=0;i<8;i++)p[i]=v[i];
		}
	}
	fprintf(stderr,"%ld samples, %.1f us each\n",n,dur*1000/n);
}
