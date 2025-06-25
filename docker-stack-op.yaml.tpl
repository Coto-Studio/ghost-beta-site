---
services:
  db:
    image: mariadb:11
    environment:
      MARIADB_USER: {{ op://${VAULT_ID}/$ITEM_ID/mysql/user }}
      MARIADB_PASSWORD: {{ op://${VAULT_ID}/$ITEM_ID/mysql/password }}
      MARIADB_DATABASE: {{ op://${VAULT_ID}/$ITEM_ID/mysql/database }}
      MARIADB_ALLOW_EMPTY_ROOT_PASSWORD: "yes"
    networks:
      - ghost
    volumes:
      - db_data:/var/lib/mysql
      - backups:/docker-entrypoint-initdb.d
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      start_period: 10s
      interval: 10s
      timeout: 5s
      retries: 3
    labels:
      - docker-volume-backup.archive-pre=/bin/sh -c 'mariadb-dump {{ op://${VAULT_ID}/$ITEM_ID/mysql/database }} > /docker-entrypoint-initdb.d/{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-{{ op://${VAULT_ID}/$ITEM_ID/mysql/database }}.sql'
      - docker-volume-backup.exec-label={{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}_db

  ghost:
    image: ghcr.io/coto-studio/{{ op://${VAULT_ID}/$ITEM_ID/deploy/containerImage }}:latest
    networks:
      - ghost
      - traefik-public
    environment:
      NODE_ENV: ${NODE_ENV:-production}
      url: "https://{{ op://${VAULT_ID}/$ITEM_ID/domain/${GIT_BRANCH:-main} }}/"
      database__client: mysql
      database__connection__host: db
      database__connection__port: 3306
      database__connection__user: {{ op://${VAULT_ID}/$ITEM_ID/mysql/user }}
      database__connection__password: {{ op://${VAULT_ID}/$ITEM_ID/mysql/password }}
      database__connection__database: {{ op://${VAULT_ID}/$ITEM_ID/mysql/database }}
      mail__transport: SMTP
      mail__options__service: {{ op://${VAULT_ID}/$ITEM_ID/mail/service }}
      mail__options__host: {{ op://${VAULT_ID}/$ITEM_ID/mail/host }}
      mail__options__port: {{ op://${VAULT_ID}/$ITEM_ID/mail/port }}
      mail__options__secure: "true"
      mail__options__auth__user: {{ op://${VAULT_ID}/$ITEM_ID/mail/user }}
      mail__options__auth__pass: {{ op://${VAULT_ID}/$ITEM_ID/mail/password }}
      storage__active: s3
      storage__s3__accessKeyId: {{ op://${VAULT_ID}/$ITEM_ID/storage/accessKeyId }}
      storage__s3__secretAccessKey: {{ op://${VAULT_ID}/$ITEM_ID/storage/secretAccessKey }}
      storage__s3__assetHost: "https://{{ op://${VAULT_ID}/$ITEM_ID/storage/domain }}"
      storage__s3__bucket: {{ op://${VAULT_ID}/$ITEM_ID/storage/bucket }}
      storage__s3__endpoint: {{ op://${VAULT_ID}/$ITEM_ID/storage/endpoint }}
    depends_on:
      - db
    deploy:
      update_config:
        order: start-first
      labels:
        # Enable Traefik
        - "traefik.enable=true"
        - "traefik.docker.network=traefik-public"
        - "traefik.constraint-label=traefik-public"
        # Ghost Config
        - "traefik.http.services.{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-ghost.loadbalancer.server.port=2368"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-ghost-http.rule=Host(`{{ op://${VAULT_ID}/$ITEM_ID/domain/${GIT_BRANCH:-main} }}`)"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-ghost-http.entrypoints=http"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-ghost-http.middlewares=https-redirect"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-ghost-https.rule=Host(`{{ op://${VAULT_ID}/$ITEM_ID/domain/${GIT_BRANCH:-main} }}`)"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-ghost-https.entrypoints=https"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-ghost-https.tls.certresolver=le"
        # www Redirect
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-https.middlewares={{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-www-redirect"
        - "traefik.http.middlewares.{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-www-redirect.redirectregex.regex=^https?://www.{{ op://${VAULT_ID}/$ITEM_ID/domain/${GIT_BRANCH:-main} }}/(.*)"
        - "traefik.http.middlewares.{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-www-redirect.redirectregex.replacement=https://{{ op://${VAULT_ID}/$ITEM_ID/domain/${GIT_BRANCH:-main} }}/$${1}"
        - "traefik.http.middlewares.{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-www-redirect.redirectregex.permanent=true"

  proxy:
    image: ghcr.io/coto-studio/b2-proxy:latest
    environment:
      B2_KEY_ID: {{ op://${VAULT_ID}/$ITEM_ID/storage/accessKeyId }}
      B2_ACCESS_KEY: {{ op://${VAULT_ID}/$ITEM_ID/storage/secretAccessKey }}
      B2_BUCKET: {{ op://${VAULT_ID}/$ITEM_ID/storage/bucket }}
      B2_REGION: {{ op://${VAULT_ID}/$ITEM_ID/storage/region }}
      CACHE_RAM: 10m
      CACHE_DISK: 2g
      CACHE_INACTIVITY: 1h
      CACHE_MAX_AGE: 3600
      MAX_CONNECTIONS_PER_IP: 20
      DEBUG_UUID: debug
    volumes:
      - cache:/var/cache/nginx
    networks:
      - traefik-public
    deploy:
      labels:
        # Enable Traefik
        - "traefik.enable=true"
        - "traefik.docker.network=traefik-public"
        - "traefik.constraint-label=traefik-public"
        # Proxy Config
        - "traefik.http.services.{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-s3.loadbalancer.server.port=80"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-s3-http.rule=Host(`{{ op://${VAULT_ID}/$ITEM_ID/storage/domain }}`)"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-s3-http.entrypoints=http"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-s3-http.middlewares=https-redirect"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-s3-https.rule=Host(`{{ op://${VAULT_ID}/$ITEM_ID/storage/domain }}`)"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-s3-https.entrypoints=https"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}-s3-https.tls.certresolver=le"

  backup:
    image: ghcr.io/offen/docker-volume-backup:v2
    volumes:
      - backups:/backups:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    deploy:
      resources:
        limits:
          memory: 100M
    environment:
      EXEC_LABEL: {{ op://${VAULT_ID}/$ITEM_ID/deploy/serviceID }}_db
      BACKUP_SOURCES: "/backups"
      AWS_S3_PATH: "backups/"
      AWS_S3_BUCKET_NAME: {{ op://${VAULT_ID}/$ITEM_ID/storage/bucket }}
      AWS_ACCESS_KEY_ID: {{ op://${VAULT_ID}/$ITEM_ID/storage/accessKeyId }}
      AWS_SECRET_ACCESS_KEY: {{ op://${VAULT_ID}/$ITEM_ID/storage/secretAccessKey }}
      AWS_ENDPOINT: {{ op://${VAULT_ID}/$ITEM_ID/storage/endpoint }}
      GPG_PASSPHRASE: {{ op://${VAULT_ID}/$ITEM_ID/storage/gpgPassphrase }}
      NOTIFICATION_URLS: "pushover://shoutrrr:{{ op://Coto.Studio - Deploy/Pushover/Docker Swarm/API Token }}@{{ op://Coto.Studio - Deploy/Pushover/credential }}/"
      NOTIFICATION_LEVEL: "info"
      BACKUP_RETENTION_DAYS: "7"
      BACKUP_PRUNING_LEEWAY: "30s"

volumes:
  db_data:
  backups:
  cache:

networks:
  ghost:
  traefik-public:
    external: true
