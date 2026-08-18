{ pkgs, ... }:

# Userland, shared by every host: the Manjaro laptop, the Ubuntu WSL box, and
# the NixOS machine that replaces the first. Nothing here may need X, a radio or
# particular hardware — that belongs in hosts/wise-laptop.
#
# home.username and home.homeDirectory are absent on purpose: flake.nix supplies
# them per output, and the NixOS module derives them from users.users.wise.

{
  # Packages only, deliberately.
  #
  # Every dotfile in $HOME is a Dotbot symlink into ~/dotfiles. Home Manager
  # wants to own those same paths and refuses to clobber files it did not
  # create, so the two would contend the moment this file grows a `programs.*`
  # block that writes config. Migrating a path means removing it from
  # profiles/base.conf.yaml in the same change — one at a time, on purpose.
  home.packages = with pkgs; [
    bat
    tree
    htop
    fastfetch
    zenity               # backs SUDO_ASKPASS/SSH_ASKPASS in shell/env.sh

    claude-code

    # browser driving functionality
    playwright-driver.browsers

    # Also pinned by asdf in ~/.tool-versions, and shadowed by these: dotfiles'
    # shell/env.sh puts Nix ahead of asdf. Dropping the asdf side waits on the
    # WSL box running Home Manager.
    gitleaks
    gh
    jq
    just
    ripgrep
    fzf
    zoxide
    delta

    # ranger and its previews
    ranger
    highlight            # source code
    poppler-utils        # pdftotext
    ueberzugpp           # image preview backend
    imagemagick          # convert
    ffmpegthumbnailer    # video
    mediainfo
    exiftool
    atool                # archive listing
    p7zip                # 7z
    catdoc               # .doc
    odt2txt              # .odt
    xlsx2csv             # .xlsx
  ];

 # Tell Playwright where to find the Nix-bundled browser binaries
  home.sessionVariables = {
    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
   };

  programs.home-manager.enable = true;

  # silence the news alerts that pop up when rebuilding
  news.display = "silent";

  # The release whose defaults this config was written against. It is not a
  # version to bump for newness — changing it opts into changed defaults.
  home.stateVersion = "26.05";
}
