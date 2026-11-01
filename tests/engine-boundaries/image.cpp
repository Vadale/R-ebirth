
int main(){
    size_t cases=0;
    for(int merge:{1,2,3,4}) for(int tiles_x:{1,2,7}) for(int tiles_y:{1,3}) {
        const int w=tiles_x*merge,h=tiles_y*merge,n=w*h;
        for(bool paddle_order:{false,true}){
            auto positions=paddle_order?paddle(w,h,merge):qwen(w,h,merge);
            assert(positions.size()==size_t(4*n));
            // Independent coordinate-to-output-index oracle. Each coordinate
            // appears exactly once; Qwen and Paddle use different tile order.
            for(int y=0;y<h;y++) for(int x=0;x<w;x++) {
                int index=paddle_order ? ((y/merge*merge+y%merge)*tiles_x+x/merge)*merge+x%merge
                    : ((y/merge*tiles_x+x/merge)*merge+y%merge)*merge+x%merge;
                assert(positions[index]==y && positions[n+index]==x);
                assert(positions[2*n+index]==y && positions[3*n+index]==x);
            }
            cases++;
        }
    }
    for(bool reverse:{false,true}) {
        const int w=6,h=4,n=w*h,tiles=6;
        std::vector<int> map(tiles);
        for(int i=0;i<tiles;i++)map[i]=reverse?tiles-1-i:i;
        auto positions=windowed(w,h,map);
        for(int y=0;y<h;y++)for(int x=0;x<w;x++) {
            const int block=(y/2)*3+x/2;
            const int index=map[block]*4+(y%2)*2+x%2;
            assert(positions[index]==y && positions[n+index]==x);
            assert(positions[2*n+index]==y && positions[3*n+index]==x);
        }
        cases++;
    }
    printf("PASS %zu aligned image position cases; merge factors 1..4\n",cases);
}
