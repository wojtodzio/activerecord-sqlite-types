{ pkgs, ... }:

{
  languages = {
    ruby = {
      version = "3.1";
      enable = true;
    };
  };

  packages = with pkgs; [
    (sqlite.override { interactive = true; })
  ];
}
