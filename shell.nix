{ pkgs ? import <nixpkgs> { } }:
with pkgs;
mkShell {
  buildInputs = [
    stack
    cabal-install
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
    postgresql_15
  ];

  shellHook = ''
    # ...
  '';
}
