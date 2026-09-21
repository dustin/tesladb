{ pkgs ? import <nixpkgs> { } }:
with pkgs;
mkShell {
  buildInputs = [
    cabal-install
    hpack
    haskell.compiler.ghc96
    sqlite-interactive
    ffmpeg
    stylish-haskell
    hlint
    niv
    ghcid
    haskell-language-server
    haskellPackages.tasty-discover
    zlib
    postgresql
    postgresql.pg_config
    gmpxx
    libffi
  ];

  shellHook = ''
    # ...
  '';
}
