{ pkgs, ... }:

{
  home.username = "wise";
  home.homeDirectory = "/home/wise";

  # Packages only, deliberately.
  #
  # Every dotfile in $HOME is a Dotbot symlink into ~/dotfiles. Home Manager
  # wants to own those same paths and refuses to clobber files it did not
  # create, so the two would contend the moment this file grows a `programs.*`
  # block that writes config. Migrating a path means removing it from
  # profiles/base.conf.yaml in the same change — one at a time, on purpose.
  home.packages = with pkgs; [
    hello
    bat
    tree
  ];

  programs.home-manager.enable = true;
 
  # silence the news alerts that pop up when rebuilding
  news.display = "silent";
  # The release whose defaults this config was written against. It is not a
  # version to bump for newness — changing it opts into changed defaults.
  home.stateVersion = "26.05";
}
