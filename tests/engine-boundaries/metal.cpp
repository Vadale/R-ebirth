#include <initializer_list>

int main(){
    size_t cases=0;
    ggml_metal_kargs_mul_mm_id args{}; args.ne20=2;args.ne0=4096;args.ne1=8;args.ne11=1;
    for(int token:{0,32767,32768,65535}){
        const int id=token*args.ne20+1;
        @I12@
        @IDT@
        const short ide=id%args.ne20;
        assert(i12==token && idt==token);
        const uint64_t offset=@MOE@;
        assert(offset==4096ULL+uint64_t(token)*8*4096);cases++;
    }
    {
        ggml_metal_kargs_mul_mm args{}; args.ne0=1048576;args.ne1=40;
        const int r0=0,r1=32,sgitg=3,im=52,j=7,i=7;
        const uint64_t full=(r0+32*(sgitg&1))+@FULL@;
        const uint64_t edge=r0+@EDGE@;
        const uint64_t store=8*(i%4)+@STORE@;
        assert(full==32ULL+48ULL*1048576+52ULL*40*1048576);
        assert(edge==39ULL*1048576+52ULL*40*1048576);
        assert(store==24ULL+8ULL*1048576);cases+=3;
    }
    {
        ggml_metal_kargs_mul_mm args{}; args.ne0=536870912;
        const int i=7;
        const uint64_t store=8*(i%4)+@STORE@;
        assert(store==24ULL+8ULL*536870912);cases++;
    }
    printf("PASS %zu Metal scalar-index cases; host arithmetic, no GPU claim\n",cases);
}
