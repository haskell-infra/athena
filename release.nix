{ athena ? { outPath = ./.; revCount = 12345; shortRev = "abcdefg"; }
, officialRelease ? false
}:

let
  system = "x86_64-linux";
  nixcfg = { allowUnfree = true; };
  pkgs   = import <nixpkgs> { config=nixcfg; };

  version = builtins.readFile ./VERSION +
    (pkgs.lib.optionalString (!officialRelease)
      "-r${toString athena.revCount}-g${athena.shortRev}");

  buildDependencies = with pkgs;
    [ perl openssh sshpass jq curl bash cacert git utillinux
      arcanist ncurses nixUnstable
    ];

  # ----------------------------------------------------------------------------

  jobs = with pkgs.lib; with builtins; rec {
    tests = let
      filterFiles = p: filterAttrs    (n: v: v == "regular") (readDir p);
      getFiles    = p: mapAttrsToList (n: v: "${p}/${n}") (filterFiles p);
      testlist    = getFiles ./src/tests;
      mkTest      = t: import t { inherit system; };
      toTest      = v: let t = mkTest v;
                       in { name = t.driver.testName; value = t; };
    in listToAttrs (map toTest testlist);

    shell = pkgs.stdenv.mkDerivation rec {
      name = "athena-env-${version}";
      inherit version;
      src = ./.;
      buildInputs = buildDependencies;
      shellHook = with pkgs; concatStringsSep "\n"
        [ "export PATH=$PWD/bin:$PATH"
          "export CURL_CA_BUNDLE=${cacert}/etc/ssl/certs/ca-bundle.crt"
#         "export NIX_PATH=$PWD/src/etc"
        ];
    };

    manual = let
      modules = import <nixpkgs/nixos/lib/eval-config.nix> {
        modules = import ./modules/module-list.nix;
        check = false;
        inherit system;
      };

      isAthena = opt: head (splitString "." opt.name) == "athena";
      filterDoc = filter (opt: isAthena opt && opt.visible && !opt.internal);
      optionsXML = toXML (filterDoc (optionAttrSetToDocList modules.options));
      optionsFile = toFile "options.xml" (unsafeDiscardStringContext optionsXML);
    in pkgs.stdenv.mkDerivation {
      name = "athena-options";

      buildInputs = singleton pkgs.libxslt;

      xsltFlags = ''
        --param section.autolabel 1
        --param section.label.includes.component.label 1
        --param html.stylesheet 'style.css'
        --param xref.with.number.and.title 1
        --param admon.style '''
      '';

      buildCommand = ''
        xsltproc -o options-db.xml \
          ${<nixpkgs/nixos/doc/manual/options-to-docbook.xsl>} \
          ${optionsFile}

        cat > manual.xml <<XML
        <book xmlns="http://docbook.org/ns/docbook"
              xmlns:xlink="http://www.w3.org/1999/xlink"
              xmlns:xi="http://www.w3.org/2001/XInclude">
          <title>Athena-specific NixOS options</title>
          <para>
            The following NixOS options are specific to Athena:
          </para>
          <xi:include href="options-db.xml" />
        </book>
        XML

        xsltproc -o "$out/manual.html" $xsltFlags -nonet -xinclude \
          ${pkgs.docbook5_xsl}/xml/xsl/docbook/xhtml/docbook.xsl \
          manual.xml

        cp "${<nixpkgs/nixos/doc/manual/style.css>}" "$out/style.css"
        mkdir -p "$out/nix-support"
        echo "doc manual $out manual.html" \
          > "$out/nix-support/hydra-build-products"
      '';
    };
  };
in jobs
