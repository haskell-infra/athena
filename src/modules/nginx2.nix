{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.nginx2;
  ncfg = cfg.config;

  defaultTo = val: def: if (val != null) then val else def;

  eventsDefaults = ''
    worker_connections 1024;
  '';

  httpPreambleDefaults = ''
    include       ${cfg.package}/conf/mime.types;
    default_type  application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  logs/access.log  main;

    sendfile       on;
    tcp_nopush     on;
    tcp_nodelay    off;
    keepalive_timeout  65;

    gzip              on;
    gzip_vary         on;
    gzip_http_version 1.1;
    gzip_comp_level   2;
    gzip_proxied      any;
    gzip_types text/plain text/css application/x-javascript
      text/xml application/xml application/xml+rss text/javascript;
  '';

  httpUpstreams = concatStringsSep "\n" (mapAttrsToList (name: servers: ''
    upstream ${name} {
      ${concatStringsSep "\n" servers}
    }
  '') ncfg.http.upstreams);

  httpServers = concatStringsSep "\n" ncfg.http.servers;

  configFile = pkgs.writeText "nginx.conf" ''
    user ${cfg.user} ${cfg.group};
    worker_processes ${toString ncfg.workerProcesses};
    error_log logs/error.log;
    pid       logs/nginx.pid;
    daemon off;

    ${defaultTo ncfg.extraMainConfig ""}

    events {
      ${defaultTo ncfg.events eventsDefaults}
    }

    http {
      ${defaultTo ncfg.http.preamble httpPreambleDefaults}
      ${httpUpstreams}
      ${httpServers}
    }
  '';

in
{
  options = {
    services.nginx2 = {
      enable = mkOption {
        default = false;
        type = types.bool;
        description = "
          Enable the nginx Web Server.
        ";
      };

      package = mkOption {
        default = pkgs.nginx;
        type = types.package;
        description = "
          Nginx package to use.
        ";
      };

      stateDir = mkOption {
        default = "/var/nginx";
        description = "Directory holding all state for nginx to run.";
      };

      user = mkOption {
        type = types.str;
        default = "www-data";
        description = "User account under which nginx runs.";
      };

      group = mkOption {
        type = types.str;
        default = "www-data";
        description = "Group account under which nginx runs.";
      };

      config = {
        workerProcesses = mkOption {
          type = types.int;
          default = 1;
          description = "Number of nginx worker processes.";
        };

        events = mkOption {
          type = types.nullOr types.lines;
          default = null;
          description = "NIH";
        };

        http = {
          preamble = mkOption {
            type = types.nullOr types.lines;
            default = null;
            description = "NIH";
          };

          upstreams = mkOption {
            type = types.attrsOf (types.listOf types.str);
            default = {};
            example = literalExample ''
              {
                upstream1 =
                  [ "server backend1.example.com       weight=5;"
                    "server backend2.example.com:8080;"
                    "server unix:/tmp/backend3;"
                    "server backup1.example.com:8080   backup;"
                    "server backup2.example.com:8080   backup;"
                  ];
              }
            '';
            description = "NIH";
          };

          servers = mkOption {
            type = types.listOf types.lines;
            default = [];
            description = "NIH";
          };
        };

        extraMainConfig = mkOption {
          type = types.nullOr types.lines;
          default = null;
          description = "NIH";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    systemd.services.nginx = {
      description = "Nginx Server";
      after    = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      path = [ cfg.package ];
      preStart =
        ''
        mkdir -p ${cfg.stateDir}/logs
        chmod 700 ${cfg.stateDir}
        chown -R ${cfg.user}:${cfg.group} ${cfg.stateDir}

        # Check syntax
        exec ${cfg.package}/bin/nginx -t -c ${configFile} -p ${cfg.stateDir};
        '';
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/nginx -c ${configFile} -p ${cfg.stateDir}";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        RestartSec = "10s";
        StartLimitInterval = "1min";
      };
    };

    users.extraGroups.www-data.name = "www-data";
    users.extraUsers.www-data = {
      description = "HTTP/WWW user";
      home = "/var/www";
      createHome = true;
      group = "www-data";
    };
  };
}
