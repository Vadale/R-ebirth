
int main() {
    size_t cases=0;
    for (size_t n : {size_t(1),size_t(8),size_t(128),size_t(2048)}) {
        llama_grammar_rules rules(1);
        std::vector<uint32_t> chars;
        // Up to 2048 decoded scalars, the public JSON string limit. Each legal
        // surrogate-pair escape uses twelve token code points before decoding.
        std::string text="\"";
        for(size_t i=0;i<n;i++) text += "\\ud83d\\ude00";
        text += "\"";
        for(unsigned char c:text){rules[0].push_back({LLAMA_GRETYPE_CHAR,c});chars.push_back(c);}
        rules[0].push_back({LLAMA_GRETYPE_END,0});chars.push_back(0);
        llama_grammar_stack stack{rules[0].data()};
        llama_grammar_candidates candidates{{17,chars.data(),{0,0},3}};
        auto rejected=llama_grammar_reject_candidates_for_stack(rules,stack,candidates);
        assert(rejected.empty()); cases++;
        chars[chars.size()-2]='x';
        rejected=llama_grammar_reject_candidates_for_stack(rules,stack,candidates);
        assert(rejected.size()==1 && rejected[0].index==17 && rejected[0].code_points==chars.data()); cases++;
    }
    llama_grammar_rules rules{{{LLAMA_GRETYPE_CHAR,0x20ac},{LLAMA_GRETYPE_END,0}}};
    uint32_t empty[]={0};
    llama_grammar_stack stack{rules[0].data()};
    // A valid prefix of U+20AC and a prefix that cannot match it.
    llama_grammar_candidates candidates{{1,empty,{0x82,1},2},{2,empty,{0x83,1},3}};
    auto rejected=llama_grammar_reject_candidates_for_stack(rules,stack,candidates);
    assert(rejected.size()==1 && rejected[0].index==2); cases++;
    rules={{{LLAMA_GRETYPE_TOKEN,7},{LLAMA_GRETYPE_END,0}}};
    uint32_t nonempty[]={'x',0}; stack={rules[0].data()};
    candidates={{1,nonempty,{0,0},7},{2,nonempty,{0,0},8}};
    rejected=llama_grammar_reject_candidates_for_stack(rules,stack,candidates);
    assert(rejected.size()==1 && rejected[0].index==2); cases++;
    assert(llama_grammar_reject_candidates_for_stack(rules,stack,{}).empty()); cases++;
    printf("PASS %zu grammar candidate cases under 2 MiB stack\n",cases);
}
