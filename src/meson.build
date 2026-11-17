blueprints = custom_target('blueprints',
  input: files(
    'dialogs/notification-dialog.blp',
    'dialogs/preferences-dialog.blp',
    'shortcuts-dialog.blp',
    'widgets/notification-row.blp',
    'window.blp',
  ),
  output: '.',
  command: [
    find_program('blueprint-compiler'),
    'batch-compile', '@OUTPUT@', '@CURRENT_SOURCE_DIR@', '@INPUT@',
  ],
)

resources = gnome.compile_resources('toastrack-resources',
  'toastrack.gresource.xml',
  c_name: 'toastrack',
  dependencies: blueprints,
)

deps = [
  dependency('gtk4', version: '>= 4.18'),
  # Wayland only
  dependency('gtk4-wayland'),
  dependency('libadwaita-1', version: '>= 1.8'),
  dependency('gio-unix-2.0'),
  dependency('sqlite3'),
  meson.get_compiler('vala').find_library('config', dirs: meson.current_source_dir()),
]

# Models and services, without UI, shared with the tests
core_lib = static_library('toastrack-core',
  files(
    'models/app-identity.vala',
    'models/notification-list.vala',
    'models/notification.vala',
    'services/history.vala',
    'services/recorder.vala',
    'utils.vala',
  ),
  dependencies: deps,
  include_directories: config_inc,
  vala_args: ['--target-glib=2.80'],
)
core_dep = declare_dependency(
  link_with: core_lib,
  dependencies: deps,
  include_directories: [config_inc, include_directories('.')],
)

sources = files(
  'application.vala',
  'dialogs/day-dialog.vala',
  'dialogs/notification-dialog.vala',
  'dialogs/preferences-dialog.vala',
  'main.vala',
  'widgets/app-row.vala',
  'widgets/notification-row.vala',
  'window.vala',
)

executable('toastrack', sources, resources,
  dependencies: [deps, core_dep],
  include_directories: config_inc,
  vala_args: [
    '--target-glib=2.80',
    '--gresourcesdir=' + meson.current_build_dir(),
  ],
  install: true,
)
