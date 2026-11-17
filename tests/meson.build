test_history = executable('test-history', 'test-history.vala',
  dependencies: core_dep,
  vala_args: ['--target-glib=2.80'],
)

test('history', test_history,
  env: [
    'XDG_DATA_HOME=' + meson.current_build_dir() / 'test-data',
    'TOASTRACK_SCHEMA=' + meson.project_source_root() / 'daemon' / 'src' / 'schema.sql',
  ],
)
