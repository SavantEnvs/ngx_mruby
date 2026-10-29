# Two builds of the embedded mruby (ngx_mruby/mruby), selected by the gems they link:
#  - host: NORMAL flags, full core gem set + mrbtest. This is the functional oracle (mayhem/test.sh).
#  - fuzz: libmruby.a built with the sanitizer/DWARF flags from the environment plus libFuzzer coverage
#    instrumentation (without it libFuzzer/Mayhem see only the harness's own 2 edges). io/socket/dir/
#    exit/sleep gems are left out so fuzzed Ruby cannot touch files, processes or the network or call exit().
san = ENV.fetch('SANITIZER_FLAGS', '').split
dbg = ENV.fetch('DEBUG_FLAGS', '').split

MRuby::Build.new do |conf|
  conf.toolchain :clang
  conf.gembox 'stdlib'
  conf.gembox 'stdlib-ext'
  conf.gembox 'math'
  conf.gembox 'metaprog'
  conf.gem core: 'mruby-print'
  conf.gem core: 'mruby-bin-mrbc'
  conf.enable_test
end

MRuby::CrossBuild.new('fuzz') do |conf|
  conf.toolchain :clang
  conf.gembox 'stdlib'
  conf.gembox 'stdlib-ext'
  conf.gembox 'math'
  conf.gembox 'metaprog'
  conf.gem core: 'mruby-print'
  [conf.cc, conf.linker].each { |c| c.flags += ['-O1', '-fsanitize=fuzzer-no-link'] + san + dbg }
end
