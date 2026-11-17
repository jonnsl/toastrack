cargo = find_program('cargo')

cargo_profile = get_option('buildtype') == 'debug' ? 'debug' : 'release'
cargo_target_dir = meson.current_build_dir() / 'target'

daemon = custom_target('toastrack-daemon',
  output: 'toastrack-daemon',
  console: true,
  build_always_stale: true,
  build_by_default: true,
  install: true,
  install_dir: get_option('libexecdir') / 'toastrack',
  command: [
    find_program('../build-aux/cargo-build.sh'),
    cargo, meson.current_source_dir(), cargo_target_dir, cargo_profile, '@OUTPUT@',
  ],
)

service_conf = configuration_data()
service_conf.set('daemon_path', get_option('prefix') / get_option('libexecdir') / 'toastrack' / 'toastrack-daemon')

systemd = dependency('systemd', required: false)
if systemd.found()
  user_unit_dir = systemd.get_variable(pkgconfig: 'systemd_user_unit_dir',
    pkgconfig_define: ['prefix', get_option('prefix')])
else
  user_unit_dir = get_option('prefix') / 'lib' / 'systemd' / 'user'
endif

configure_file(
  input: 'toastrack.service.in',
  output: 'toastrack.service',
  configuration: service_conf,
  install: true,
  install_dir: user_unit_dir,
)

test('daemon', cargo,
  args: ['test', '--manifest-path', meson.current_source_dir() / 'Cargo.toml',
         '--target-dir', cargo_target_dir],
  timeout: 600,
)
