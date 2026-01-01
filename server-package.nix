{ pkgs, lib }:

pkgs.stdenv.mkDerivation {
  pname = "nix-build-server";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  buildInputs = [ pkgs.uv pkgs.python3 ];

  installPhase = ''
    mkdir -p $out/bin

    # Install Python server with UV shebang
    cp ${./server/build-server.py} $out/bin/build-server
    chmod +x $out/bin/build-server

    # Install bash build script
    cp ${./server/build-repository.sh} $out/bin/build-repository
    chmod +x $out/bin/build-repository

    # Wrap to ensure dependencies in PATH
    wrapProgram $out/bin/build-server \
      --prefix PATH : ${lib.makeBinPath [
        pkgs.uv
        pkgs.curl
        pkgs.jq
        pkgs.systemd
        pkgs.nix
        pkgs.coreutils
      ]}

    wrapProgram $out/bin/build-repository \
      --prefix PATH : ${lib.makeBinPath [
        pkgs.git
        pkgs.nix
        pkgs.bash
        pkgs.coreutils
        pkgs.jq
        pkgs.gnused
        pkgs.findutils
      ]}
  '';

  meta = {
    description = "NixOS build server with binary cache";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
