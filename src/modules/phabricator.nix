{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.phabricator;

  ## ---------------------------------------------------------------------------
  ## -- Nginx options

  maintenancePage = pkgs.writeText "maintenance.html"
    (builtins.readFile ./phab-maintenance.html);

  /**
   * Default TLS options for high security, OCSP stapling, etc.
   * See https://wiki.mozilla.org/Security/Server_Side_TLS
   */
  httpsTlsOpts = ''
    ssl_certificate         <CERTPATH>;
    ssl_trusted_certificate <CERTPATH>;
    ssl_certificate_key     <CERTPATH>;

    resolver 8.8.8.8;
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 5m;
    ssl_protocols TLSv1.2 TLSv1.1 TLSv1;
    ssl_prefer_server_ciphers on;

    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:ECDHE-RSA-RC4-SHA:ECDHE-ECDSA-RC4-SHA:AES128:AES256:RC4-SHA:HIGH:!aNULL:!eNULL:!EXPORT:!DES:!3DES:!MD5:!PSK;
  '';

  httpServerConfig = ''
    server {
      server_name ${cfg.baseURI} ${cfg.baseFilesURI};
      listen 80; listen [::]:80;

      location / {
        return 302 https://$host$request_uri;
      }
    }
  '';

  maintenanceConfig  = pkgs.writeText "nginx-phabricator-maintenance.conf" ''
    error_page   503 @maintenance;
    location @maintenance {
      root /var/phabricator/maintenance;
      rewrite ^(.*)$ /index.html break;
    }

    location / { return 503; }
  '';

  phabConfig = pkgs.writeText "nginx-phabricator.conf" ''
    ## -- The following is the recommended Phabricator config for Nginx.
    client_max_body_size ${cfg.uploadLimit};
    root /var/phabricator/phabricator/webroot;

    location / {
      index index.php;
      rewrite ^/(.*)$ /index.php?__path__=/$1 last;
    }

    location = /favicon.ico {
      try_files $uri =204;
    }

    location /index.php {
      fastcgi_pass    unix:/run/phpfpm/phabricator.sock;
      fastcgi_index   index.php;

      #required if PHP was built with --enable-force-cgi-redirect
      fastcgi_param  REDIRECT_STATUS    200;
      #variables to make the $_SERVER populate in PHP
      fastcgi_param  SCRIPT_FILENAME    $document_root$fastcgi_script_name;
      fastcgi_param  QUERY_STRING       $query_string;
      fastcgi_param  REQUEST_METHOD     $request_method;
      fastcgi_param  CONTENT_TYPE       $content_type;
      fastcgi_param  CONTENT_LENGTH     $content_length;
      fastcgi_param  SCRIPT_NAME        $fastcgi_script_name;
      fastcgi_param  GATEWAY_INTERFACE  CGI/1.1;
      fastcgi_param  SERVER_SOFTWARE    nginx/$nginx_version;
      fastcgi_param  REMOTE_ADDR        $remote_addr;
    }
  '';

  httpsServerConfig = ''
    server {
      server_name ${cfg.baseURI} ${cfg.baseFilesURI};
      listen 443 ssl spdy; listen [::]:443 ssl spdy;

      ${httpsTlsOpts}

      include /var/phabricator/nginx.conf;
    }
  '';

  ## ---------------------------------------------------------------------------
  ## -- PHP Package configurations ---------------------------------------------

  php = pkgs.php54;
  pecl = import <nixpkgs/pkgs/build-support/build-pecl.nix> {
    inherit php; inherit (pkgs) stdenv autoreconfHook fetchurl;
  };
  phab-apc = pecl rec {
    # APC 3.1.13 is recommended for Phabricator
    name = "apc-3.1.13";
    src = pkgs.fetchurl {
      url = "https://pecl.php.net/get/APC-3.1.13.tgz";
      sha256 = "1gcsh9iar5qa1yzpjki9bb5rivcb6yjp45lmjmp98wlyf83vmy2y";
    };
  };

  phab-scrypt = pecl rec {
    name = "scrypt-1.2";
    sha256 = "1yan3ya84bnjzspbfg46xw0whzj4f9zrmhl1c10f3m7mplr9n25m";
  };

  phab-xhprof = pecl rec {
    name = "xhprof-0.9.2-20150715";
    src = pkgs.fetchgit {
      url    = "https://github.com/phacility/xhprof.git";
      rev    = "0bbf2a2ac34f495e42aa852293fe0ed821659047";
      sha256 = "b3e2f666d9d55b86dd8a26ac1984ae850992732f1afa53ed0b7f17ff842d1e37";
    };
    setSourceRoot = "export sourceRoot=$(echo xhprof-*/extension/)";
  };

  phpIni = pkgs.runCommand "php.ini" {} ''
    cat ${php}/etc/php-recommended.ini > $out

    echo "extension=${phab-apc}/lib/php/extensions/apc.so" >> $out
    echo "extension=${phab-scrypt}/lib/php/extensions/scrypt.so" >> $out
    echo "extension=${phab-xhprof}/lib/php/extensions/xhprof.so" >> $out
    echo "apc.stat = '0'" >> $out
    echo "apc.slam_defense = '0'" >> $out
    substituteInPlace $out \
      --replace "upload_max_filesize = 2M" \
                "upload_max_filesize = ${cfg.uploadLimit}"
    substituteInPlace $out \
      --replace "post_max_size = 8M" \
                "post_max_size = ${cfg.uploadLimit}"
  '';

  ## ---------------------------------------------------------------------------
  ## -- Phabricator files and utilities ----------------------------------------

  mysqlStopwords = pkgs.fetchurl {
    url    = "https://raw.githubusercontent.com/phacility/phabricator/e616f166ae9ffaf350468e510fb21d16b36060a5/resources/sql/stopwords.txt";
    sha256 = "14bi5dah7nx6bd8h525alqxgs0dxqfaanpyhqys1pssa4bg4pvjk";
  };

  phabSshHookSrc = pkgs.writeText "phabricator-ssh-hook.sh" ''
    #!${pkgs.bash}/bin/bash

    VCSUSER="vcs"
    ROOT="/var/phabricator/phabricator"

    if [ "$1" != "$VCSUSER" ]; then exit 1; fi

    exec ${php}/bin/php "$ROOT/bin/ssh-auth" $@
  '';

  phabSshConfig = pkgs.writeText "phabricator_ssh_config" ''
    AuthorizedKeysCommand /etc/ssh/phabricator-ssh-hook.sh
    AuthorizedKeysCommandUser vcs
    AllowUsers vcs

    # You may need to tweak these options, but mostly they just turn off everything
    # dangerous.

    Port 22
    Protocol 2
    PermitRootLogin no
    AllowAgentForwarding no
    AllowTcpForwarding no
    PrintMotd no
    PrintLastLog no
    PasswordAuthentication no
    AuthorizedKeysFile none

    PidFile /run/phabricator-sshd.pid
    HostKey /etc/ssh/ssh_host_dsa_key
    HostKey /etc/ssh/ssh_host_ecdsa_key
    HostKey /etc/ssh/ssh_host_ed25519_key
  '';

  # Useful administration package for Phabricator
  phab-admin = pkgs.stdenv.mkDerivation rec {
    name = "phab-admin";
    buildInputs = [ pkgs.makeWrapper ];

    phases = "installPhase";
    installPhase = ''
      mkdir -p $out/bin $out/libexec

      ## ------------------------
      ## -- Upgrade script
      cat > $out/libexec/phabricator-do-upgrade <<EOF
      #!${pkgs.bash}/bin/bash
      set -e

      if [ "\$(whoami)" != "phabricator" ]; then
        echo "err: must be run as the phabricator user"
        exit 1
      fi

      ROOT=/var/phabricator
      PHUTIL=\$ROOT/libphutil
      ARC=\$ROOT/arcanist
      PHAB=\$ROOT/phabricator

      PASS=\$MYSQL_PASSWORD

      echo -n "msg: upgrading code... "
      (cd \$PHUTIL && ${pkgs.git}/bin/git checkout master && ${pkgs.git}/bin/git pull origin master) > \
        /dev/null 2>&1
      (cd \$ARC && ${pkgs.git}/bin/git checkout master && ${pkgs.git}/bin/git pull origin master) > \
        /dev/null 2>&1
      (cd \$PHAB && ${pkgs.git}/bin/git checkout master && ${pkgs.git}/bin/git pull origin master) > \
        /dev/null 2>&1
      ${concatStringsSep "\n" (mapAttrsToList (name: val: ''
        (cd \$ROOT/${name} && ${pkgs.git}/bin/git checkout master && ${pkgs.git}/bin/git pull origin master) > \
        /dev/null 2>&1
      '') cfg.extensions)}
      echo OK

      echo -n "msg: upgrading database... "
      \$PHAB/bin/storage upgrade --force --user root \$PASS > /dev/null 2>&1
      echo OK
      EOF
      chmod +x $out/libexec/phabricator-do-upgrade

      ## ------------------------
      ## -- Stop script
      cat > $out/libexec/phabricator-stop <<EOF
      #!${pkgs.bash}/bin/bash
      set -e
      ROOT=/var/phabricator
      PHAB=\$ROOT/phabricator

      echo -n "msg: putting nginx in maintenance mode... "
      /var/setuid-wrappers/sudo ln -sf ${maintenanceConfig} /var/phabricator/nginx.conf
      /var/setuid-wrappers/sudo ${pkgs.systemd}/bin/systemctl reload nginx
      echo OK
      echo -n "msg: stopping phpfpm... "
      /var/setuid-wrappers/sudo ${pkgs.systemd}/bin/systemctl stop phpfpm
      echo OK
      echo -n "msg: stopping phabricator daemons... "
      /var/setuid-wrappers/sudo -u phabricator -- \$PHAB/bin/phd stop > /dev/null 2>&1
      echo OK
      EOF
      chmod +x $out/libexec/phabricator-stop

      ## ------------------------
      ## -- Start script
      cat > $out/libexec/phabricator-start <<EOF
      #!${pkgs.bash}/bin/bash
      set -e
      ROOT=/var/phabricator
      PHAB=\$ROOT/phabricator

      echo -n "msg: starting phabricator daemons... "
      /var/setuid-wrappers/sudo -u phabricator -- \$PHAB/bin/phd start > /dev/null 2>&1
      echo OK
      echo -n "msg: starting phpfpm... "
      /var/setuid-wrappers/sudo ${pkgs.systemd}/bin/systemctl start phpfpm
      echo OK
      echo -n "msg: moving nginx out of maintenance mode... "
      /var/setuid-wrappers/sudo ln -sf ${phabConfig} /var/phabricator/nginx.conf
      /var/setuid-wrappers/sudo ${pkgs.systemd}/bin/systemctl reload nginx
      echo OK
      EOF
      chmod +x $out/libexec/phabricator-start

      ## ------------------------
      ## -- Upgrade script
      cat > $out/libexec/phabricator-upgrade <<EOF
      #!${pkgs.bash}/bin/bash
      set -e

      export MYSQL_PASSWORD=\$(${pkgs.systemd}/bin/systemd-ask-password "Enter MySQL root password (or leave empty for none):")
      $out/libexec/phabricator-stop
      /var/setuid-wrappers/sudo -E -u phabricator -- ${pkgs.bash}/bin/bash -c "exec $out/libexec/phabricator-do-upgrade"
      $out/libexec/phabricator-start
      EOF
      chmod +x $out/libexec/phabricator-upgrade

      ## ------------------------
      ## -- Restart script
      cat > $out/libexec/phabricator-restart <<EOF
      #!${pkgs.bash}/bin/bash
      set -e
      $out/libexec/phabricator-stop
      $out/libexec/phabricator-start
      EOF
      chmod +x $out/libexec/phabricator-restart

      ## ------------------------
      ## -- Primary admin script
      cat > $out/bin/phabricator <<EOF
      #!${pkgs.bash}/bin/bash
      NAME=\$1
      shift

      if [ "x\$NAME" = "x" ]; then echo "err: a command is required" && exit 1; fi
      if [ "\$NAME" = "--upgrade" ]; then exec $out/libexec/phabricator-upgrade; fi
      if [ "\$NAME" = "--stop"    ]; then exec $out/libexec/phabricator-stop; fi
      if [ "\$NAME" = "--start"   ]; then exec $out/libexec/phabricator-start; fi
      if [ "\$NAME" = "--restart" ]; then exec $out/libexec/phabricator-restart; fi

      CMD="/var/phabricator/phabricator/bin/\$NAME"
      for i in "\$@"; do
        CMD="\$CMD '\$i'";
      done
      exec /var/setuid-wrappers/sudo -u phabricator -- ${pkgs.bash}/bin/bash -c "\$CMD"
      EOF
      chmod +x $out/bin/phabricator
    '';
  };

in
{
  ## ---------------------------------------------------------------------------
  ## -- Service options --------------------------------------------------------
  options = {
    services.phabricator = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "If enabled, enable Phabricator with php-fpm.";
      };

      src = mkOption {
        type = types.attrsOf types.str;
        description = "Location of Phabricator source repositories.";
        default = {
          libphutil        = "git://github.com/phacility/libphutil.git";
          arcanist         = "git://github.com/phacility/arcanist.git";
          phabricator      = "git://github.com/phacility/phabricator.git";
        };
      };

      extensions = mkOption {
        type = types.attrsOf types.str;
        description = "List of Phabricator extensions to clone/update";
        default = {};
      };

      baseURI = mkOption {
        type = types.str;
        description = "The FQDN of your installation, e.g. <literal>reviews.examplecorp.com</literal>";
      };

      baseFilesURI = mkOption {
        type = types.str;
        description = "The FQDN of your file hosting URI that points to the same server (e.g. <literal>phabricator.examplecorpcdncontent.com</literal>)";
      };

      uploadLimit = mkOption {
        type = types.str;
        default = "64M";
        description = ''
          Limit for file size upload chunks, used to set PHP/Nginx
          options. Note that Phabricator itself can store arbitrarily
          large files, as long as the webserver and PHP allow at least
          a 32M minimum upload size. As a result you should almost
          never need to modify this value; your server will
          automatically support arbitrarily large files out of the
          box.
        '';
      };
    };
  };

  ## ---------------------------------------------------------------------------
  ## -- Service implementation -------------------------------------------------
  config = mkIf cfg.enable {

    environment.systemPackages =
      [ php phab-admin pkgs.nodejs pkgs.which pkgs.imagemagick
        pkgs.jq pkgs.pythonPackages.pygments ];

    environment.etc =
      [ { target = "ssh/phabricator-ssh-hook.sh";
          source = phabSshHookSrc;
          mode   = "755";
          uid    = config.ids.uids.root;
        }
      ];

    ## -------------------------------------------------------------------------
    ## -- Systemd services -----------------------------------------------------

    systemd.services."phabricator-init" =
      { wantedBy = [ "multi-user.target" ];
        requires = [ "network.target" "mysql.service" ];
        before   = [ "nginx.service" ];

        path = [ php ];
        script = ''
          cd /var/phabricator

          if [ ! -d libphutil ]; then
            /var/setuid-wrappers/sudo -u phabricator -- ${pkgs.git}/bin/git clone ${cfg.src.libphutil}
          fi
          if [ ! -d arcanist ]; then
            /var/setuid-wrappers/sudo -u phabricator -- ${pkgs.git}/bin/git clone ${cfg.src.arcanist}
          fi
          if [ ! -d phabricator ]; then
            /var/setuid-wrappers/sudo -u phabricator -- ${pkgs.git}/bin/git clone ${cfg.src.phabricator}
          fi

          ${concatStringsSep "\n" (mapAttrsToList (name: val: ''
            if [ ! -d ${name} ]; then
              /var/setuid-wrappers/sudo -u phabricator -- ${pkgs.git}/bin/git clone ${val} ${name}
            fi
          '') cfg.extensions)}

          if [ -f .phabinitdone ]; then exit 0; fi

          mkdir -p /var/phabricator/data /var/phabricator/repos /var/phabricator/tmp/phd/log /var/phabricator/tmp/phd/pid /var/phabricator/maintenance
          chown -R phabricator:phabricator /var/phabricator
          chmod 701 /var/phabricator # So nginx can read the maintenance page

          cp ${maintenancePage} /var/phabricator/maintenance/index.html
          ln -s ${phabConfig} /var/phabricator/nginx.conf

          ${phab-admin}/bin/phabricator config set phd.user                      phabricator
          ${phab-admin}/bin/phabricator config set diffusion.ssh-user            vcs
          ${phab-admin}/bin/phabricator config set diffusion.allow-http-auth     true
          ${phab-admin}/bin/phabricator config set repository.default-local-path /var/phabricator/repos
          ${phab-admin}/bin/phabricator config set storage.local-disk.path       /var/phabricator/data
          ${phab-admin}/bin/phabricator config set phd.pid-directory             /var/phabricator/tmp/phd/log
          ${phab-admin}/bin/phabricator config set phd.log-directory             /var/phabricator/tmp/phd/pid

          ${phab-admin}/bin/phabricator config set metamta.default-address       "noreply@${cfg.baseURI}" # Default From:
          ${phab-admin}/bin/phabricator config set metamta.domain                "${cfg.baseURI}"         # Domain to send from
          ${phab-admin}/bin/phabricator config set metamta.reply-handler-domain  "${cfg.baseURI}"         # Reply handler domain

          ${phab-admin}/bin/phabricator config set metamta.mail-adapter          "PhabricatorMailImplementationMailgunAdapter"
          ${phab-admin}/bin/phabricator config set mailgun.domain                "${cfg.baseURI}"

          ${phab-admin}/bin/phabricator config set phabricator.base-uri          "https://${cfg.baseURI}"
          ${phab-admin}/bin/phabricator config set security.alternate-file-domain "https://${cfg.baseFilesURI}"
          ${phab-admin}/bin/phabricator config set mysql.port                    3306
          ${phab-admin}/bin/phabricator config set storage.mysql-engine.max-size 0
          ${phab-admin}/bin/phabricator config set pygments.enabled              true
          ${phab-admin}/bin/phabricator config set files.enable-imagemagick      true
          ${phab-admin}/bin/phabricator config set phabricator.timezone          ${config.time.timeZone}
          ${phab-admin}/bin/phabricator config set environment.append-paths      '["/run/current-system/sw/bin", "/run/current-system/sw/sbin"]'
          ${phab-admin}/bin/phabricator config set load-libraries                '["/var/phabricator/libphutil-scrypt/src"]'
          touch .phabinitdone; chown phabricator:phabricator .phabinitdone
        '';

        serviceConfig.User = "root";
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
      };

    ## -- PHP-FPM pools
    services.phpfpm.phpPackage = php;
    services.phpfpm.phpIni = phpIni;
    services.phpfpm.poolConfigs =
      { phabricator = ''
          listen = /run/phpfpm/phabricator.sock
          listen.owner = www-data
          listen.group = www-data
          user = phabricator
          pm = dynamic
          pm.max_children = 75
          pm.start_servers = 10
          pm.min_spare_servers = 5
          pm.max_spare_servers = 20
          pm.max_requests = 500
        '';
      };

    ## -- MariaDB in a private container
    services.mysql.enable = true;
    services.mysql.package = pkgs.mariadb;
    services.mysql.extraOptions = ''
      sql_mode=STRICT_ALL_TABLES
      ft_min_word_len=3
      ft_stopword_file=${mysqlStopwords}
      ft_boolean_syntax=' |-><()~*:""&^'
      max_allowed_packet=40000000
      innodb_buffer_pool_size=500M
    '';

    ## -- Nginx
    services.nginx2.config = {
      http.servers = [ httpServerConfig httpsServerConfig ];
    };

    ## -------------------------------------------------------------------------
    ## -- Users ----------------------------------------------------------------

    users.extraUsers.phabricator = {
      description = "Phabricator User";
      home = "/var/phabricator";
      createHome = true;
      group = "phabricator";
      useDefaultShell = true;
    };

    users.extraUsers.vcs = {
      description = "Phabricator VCS User";
      home = "/var/vcs";
      createHome = true;
      group = "vcs";
      useDefaultShell = true;
      hashedPassword = "NP";
    };

    users.extraGroups.phabricator.name = "phabricator";
    users.extraGroups.vcs.name = "vcs";

    ## -------------------------------------------------------------------------
    ## -- VCS Repository support -----------------------------------------------

    # Ensure the default SSH instance (which has a perfectly OK configuration)
    # is run only on port 222, so we can run a special one on the real 22.
    services.openssh.ports = [ 222 ];

    # And punch in the firewall rules...
    networking.firewall.allowedTCPPorts =
      [ 22  # Git/SSH support
        222 # SSH administration port
      ];

    # Set up specific sudo rules
    security.sudo.extraConfig = lib.concatStringsSep "\n"
     [
       ## -- Enable the vcs/www user to sudo as the daemon user.
       ("vcs ALL=(phabricator) SETENV: NOPASSWD: "+
        "${pkgs.git}/bin/git-upload-pack, ${pkgs.git}/bin/git-receive-pack, "+
        "${pkgs.mercurial}/bin/hg, "+
        "${pkgs.subversion}/bin/svnserve")

       ## -- Enable the nginx user to sudo as the daemon user.
       ("nginx ALL=(phabricator) SETENV: NOPASSWD: "+
        "${pkgs.git}/libexec/git-core/git-http-backend, "+
        "${pkgs.mercurial}/bin/hg")
     ];

    systemd.services."phabricator-sshd" =
      { wantedBy = [ "multi-user.target" ];
        requires = [ "network.target" ];

        serviceConfig.KillMode = "process";
        serviceConfig.Restart = "always";
        serviceConfig.Type = "forking";
        serviceConfig.PIDFile = "/run/phabricator-sshd.pid";
        serviceConfig.ExecStart =
          "${pkgs.openssh}/bin/sshd -f ${phabSshConfig}";
      };
  };
}
