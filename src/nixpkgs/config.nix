{
  allowUnfree = true;
  allowBroken = true;

# ------------------------------------------------------------------------------
# -- Begin package changes -----------------------------------------------------
  packageOverrides = pkgs: with pkgs;
  let
    commonBuildTools =
      [ autoconf automake libtool ninja clang perl git mercurial
      ];

  in
  rec {

# ------------------------------------------------------------------------------
# -- The end -------------------------------------------------------------------
  };
}
