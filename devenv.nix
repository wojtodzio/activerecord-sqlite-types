{ pkgs, ... }:

{
  languages = {
    ruby = {
      version = "3.1";
      enable = true;
    };
  };

  packages = with pkgs; [
    libyaml
    pkg-config
    (sqlite.override { interactive = true; })
  ];

  services.postgres = {
    enable = true;
    initialDatabases = [
      { name = "activerecord_sqlite_types_test"; }
    ];
  };
}
