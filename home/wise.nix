{ pkgs, ... }:

# Userland, shared by every host: the Manjaro laptop, the Ubuntu WSL box, and
# the NixOS machine that replaces the first. Nothing here may need X, a radio or
# particular hardware — that belongs in hosts/wise-laptop.
#
# home.username and home.homeDirectory are deliberately absent. The two Home
# Manager outputs in flake.nix supply them, and the NixOS module derives them
# from users.users.wise, so naming them here would fix a username this file has
# no business knowing.

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

    # Also installed by asdf, which still pins them in ~/.tool-versions.
    # ~/.nix-profile/bin precedes ~/.asdf/shims, so these win everywhere except
    # in the scripts that prepend the shims themselves — the pre-commit hook,
    # asdf/verify-tools.sh, and the two gh-*-build.sh.
    #
    # Dropping the asdf side is a dotfiles change, and it is gated on the WSL
    # box running Home Manager: profiles/base.conf.yaml reaches that host within
    # 20 minutes of a commit, and removing a plugin there before Nix supplies a
    # replacement is what left it with no ranger, htop, fastfetch or zenity.
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

  programs.home-manager.enable = true;

  # silence the news alerts that pop up when rebuilding
  news.display = "silent";

  # The release whose defaults this config was written against. It is not a
  # version to bump for newness — changing it opts into changed defaults.
  home.stateVersion = "26.05";
}
