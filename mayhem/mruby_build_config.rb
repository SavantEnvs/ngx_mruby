# Two builds of the embedded mruby (ngx_mruby/mruby):
#  - host: NORMAL flags, stdlib gems + mrbtest. This is the functional oracle (mayhem/test.sh).
#  - fuzz: libmruby.a with the gem set ngx_mruby ships (build_config.rb: full-core + its own mrbgems),
#    built with the sanitizer/DWARF flags from the environment plus libFuzzer coverage instrumentation
#    (without it libFuzzer/Mayhem see only the harness's own 2 edges). Both fuzz targets link it.
#    Left out: mruby-exit and mruby-sleep (fuzzed Ruby would only report "fuzz target exited" / hang),
#    the mruby-bin-* executables (no fuzz use) and auto-ssl (needs mruby-acme-client + OpenSSL bindings,
#    only meaningful in an SSL-enabled nginx).
san = ENV.fetch('SANITIZER_FLAGS', '').split
dbg = ENV.fetch('DEBUG_FLAGS', '').split
deps = ENV.fetch('MAYHEM_MRUBY_DEPS', '/opt/mayhem-deps') # pinned gems the Dockerfile cloned

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
  Dir.glob("#{root}/mrbgems/mruby-*/mrbgem.rake").sort.each do |x| # = gembox 'full-core' minus the exclusions
    g = File.basename(File.dirname(x))
    conf.gem core: g unless g =~ /\Amruby-(?:bin-.*|test|exit|sleep)\z/
  end
  conf.gem "#{deps}/mruby-stringio"
  conf.gem "#{ENV.fetch('SRC')}/mrbgems/ngx_mruby_mrblib"
  conf.gem "#{ENV.fetch('SRC')}/mrbgems/rack-based-api"
  conf.defines << 'MRB_STR_LENGTH_MAX=10485760' # same cap as ngx_mruby's own build_config.rb
  [conf.cc, conf.linker].each { |c| c.flags += ['-O1', '-fsanitize=fuzzer-no-link'] + san + dbg }
end
