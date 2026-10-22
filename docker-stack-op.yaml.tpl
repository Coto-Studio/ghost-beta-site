---
services:
  db:
    image: mysql:8
    environment:
      MYSQL_USER: {{ op://${VAULT_ID}/$ITEM_ID/mysql/user }}
      MYSQL_PASSWORD: "{{ op://${VAULT_ID}/$ITEM_ID/mysql/password }}"
      MYSQL_DATABASE: {{ op://${VAULT_ID}/$ITEM_ID/mysql/database }}
      MYSQL_ROOT_PASSWORD: "{{ op://${VAULT_ID}/$ITEM_ID/mysql/rootPassword }}"
    networks:
      - ghost
    volumes:
      - db_data:/var/lib/mysql
      - backups:/docker-entrypoint-initdb.d
    healthcheck:
      test: ["CMD", "mysqladmin" ,"ping", "-h", "localhost"]
      start_period: 10s
      interval: 10s
      timeout: 5s
      retries: 3
    labels:
      - docker-volume-backup.archive-pre=/bin/sh -c 'mysqldump -uroot -p"{{ op://${VAULT_ID}/$ITEM_ID/mysql/rootPassword }}" {{ op://${VAULT_ID}/$ITEM_ID/mysql/database }} > /docker-entrypoint-initdb.d/{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/mysql/database }}.sql'
      - docker-volume-backup.exec-label={{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}_db

  app:
    image: {{ op://${VAULT_ID}/$ITEM_ID/deploy/image }}:latest
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
      database__connection__password: "{{ op://${VAULT_ID}/$ITEM_ID/mysql/password }}"
      database__connection__database: {{ op://${VAULT_ID}/$ITEM_ID/mysql/database }}
      database__pool__min: 0
      mail__transport: SMTP
      mail__options__service: {{ op://${VAULT_ID}/$ITEM_ID/mail/service }}
      mail__options__host: {{ op://${VAULT_ID}/$ITEM_ID/mail/host }}
      mail__options__port: {{ op://${VAULT_ID}/$ITEM_ID/mail/port }}
      mail__options__secure: "true"
      mail__options__auth__user: {{ op://${VAULT_ID}/$ITEM_ID/mail/user }}
      mail__options__auth__pass: {{ op://${VAULT_ID}/$ITEM_ID/mail/password }}
      storage__active: s3
      storage__media: s3
      storage__files: s3
      storage__s3__accessKeyId: {{ op://${VAULT_ID}/$ITEM_ID/storage/accessKeyId }}
      storage__s3__secretAccessKey: {{ op://${VAULT_ID}/$ITEM_ID/storage/secretAccessKey }}
      storage__s3__assetHost: "https://{{ op://${VAULT_ID}/$ITEM_ID/storage/domain }}"
      storage__s3__bucket: {{ op://${VAULT_ID}/$ITEM_ID/storage/bucket }}
      storage__s3__endpoint: {{ op://${VAULT_ID}/$ITEM_ID/storage/endpoint }}
      storage__s3__region: {{ op://${VAULT_ID}/$ITEM_ID/storage/region }}
    # `depends_on` is deliberately omitted: Swarm ignores it (it is Compose-only), so it
    # never provided the db-before-app ordering it appeared to. Startup ordering is
    # handled by restart_policy below.
    healthcheck:
      # Uses `node`, which is always present in the Ghost image; curl/wget are not.
      # Ghost 301s plain-HTTP requests to its https `url`. Following that redirect sends
      # the check out through Traefik, which only routes to healthy tasks, so it could
      # never pass. Don't follow it: a 2xx or that 3xx means Ghost is up (it serves 503
      # while booting or migrating).
      test:
        - CMD
        - node
        - -e
        - "fetch('http://127.0.0.1:2368/ghost/api/admin/site/', { redirect: 'manual' }).then(r => process.exit(r.status < 400 ? 0 : 1)).catch(() => process.exit(1))"
      # start_period must outlast a full migration batch. Without a healthcheck Swarm
      # treats "process started" as "healthy" and can converge away from a container
      # that is still migrating, stranding the lock row in `migrations_lock`.
      start_period: 300s
      interval: 15s
      timeout: 10s
      retries: 3
    deploy:
      update_config:
        # stop-first: never run two Ghost versions against one database. Under
        # start-first the outgoing container kept serving while the incoming one died
        # during its migration, so four consecutive failed deploys went unnoticed.
        order: stop-first
        failure_action: pause
        monitor: 300s
      restart_policy:
        # Back off instead of hammering a restart every ~7s when boot fails.
        condition: on-failure
        delay: 30s
        window: 600s
      labels:
        # Enable Traefik
        - "traefik.enable=true"
        - "traefik.docker.network=traefik-public"
        - "traefik.constraint-label=traefik-public"
        ## Service
        - "traefik.http.services.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}.loadbalancer.server.port={{ op://${VAULT_ID}/$ITEM_ID/deploy/port }}"
        ## Route HTTP
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-http.rule=Host(`{{ op://${VAULT_ID}/$ITEM_ID/domain/${GIT_BRANCH:-main} }}`)"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-http.entrypoints=http"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-http.middlewares=https-redirect"
        ## Route HTTPS
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-https.rule=Host(`{{ op://${VAULT_ID}/$ITEM_ID/domain/${GIT_BRANCH:-main} }}`)"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-https.entrypoints=https"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-https.tls.certresolver=le-http"
        #  - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-https.tls.domains[0].main={{ op://${VAULT_ID}/$ITEM_ID/domain/main }}"
        #  - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-https.tls.domains[0].sans=*.{{ op://${VAULT_ID}/$ITEM_ID/domain/cert }}"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-https.service={{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}"
        ## Route HTTP (domain2) 
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-domain2-http.rule=Host(`{{ op://${VAULT_ID}/$ITEM_ID/domain2/${GIT_BRANCH:-main} }}`)"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-domain2-http.entrypoints=http"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-domain2-http.middlewares=https-redirect"
        ## Route HTTPS (domain2)
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-domain2-https.rule=Host(`{{ op://${VAULT_ID}/$ITEM_ID/domain2/${GIT_BRANCH:-main} }}`)"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-domain2-https.entrypoints=https"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-domain2-https.tls.certresolver=le-http"
        #  - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-domain2-https.tls.domains[0].main={{ op://${VAULT_ID}/$ITEM_ID/domain2/main }}"
        #  - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-domain2-https.tls.domains[0].sans=*.{{ op://${VAULT_ID}/$ITEM_ID/domain2/cert }}"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-domain2-https.middlewares=ghost-beta-redirect"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-domain2-https.service={{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}"
        # Redirect: ghost.nelsonroberto.com -> ghost.coto.studio
        - "traefik.http.middlewares.ghost-beta-redirect.redirectregex.regex=^https?://{{ op://${VAULT_ID}/$ITEM_ID/domain2/main }}/(.*)"
        - "traefik.http.middlewares.ghost-beta-redirect.redirectregex.replacement=https://{{ op://${VAULT_ID}/$ITEM_ID/domain/main }}/$${1}"
        - "traefik.http.middlewares.ghost-beta-redirect.redirectregex.permanent=true"

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
        - "traefik.http.services.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-s3.loadbalancer.server.port=80"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-s3-http.rule=Host(`{{ op://${VAULT_ID}/$ITEM_ID/storage/domain }}`)"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-s3-http.entrypoints=http"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-s3-http.middlewares=https-redirect"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-s3-https.rule=Host(`{{ op://${VAULT_ID}/$ITEM_ID/storage/domain }}`)"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-s3-https.entrypoints=https"
        - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-s3-https.tls.certresolver=le-http"
        # - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-s3-https.tls.domains[0].main={{ op://${VAULT_ID}/$ITEM_ID/storage/domain }}"
        # - "traefik.http.routers.{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}-s3-https.tls.domains[0].sans=*.{{ op://${VAULT_ID}/$ITEM_ID/domain/cert }}"

  backup:
    image: ghcr.io/coto-studio/docker-volume-backup:v2
    volumes:
      - backups:/backups:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    deploy:
      resources:
        limits:
          memory: 100M
    environment:
      EXEC_LABEL: {{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}-{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}_db
      BACKUP_SOURCES: "/backups"
      AWS_S3_PATH: "coto-v3/{{ op://${VAULT_ID}/$ITEM_ID/deploy/stack }}/{{ op://${VAULT_ID}/$ITEM_ID/deploy/service }}"
      AWS_S3_BUCKET_NAME: {{ op://vwf67dktoxzt77frbh257llrpu/fdhockv5zsg6fzda3iig5zm7dq/storage/bucket }}
      AWS_ACCESS_KEY_ID: {{ op://vwf67dktoxzt77frbh257llrpu/fdhockv5zsg6fzda3iig5zm7dq/storage/accessKeyId }}
      AWS_SECRET_ACCESS_KEY: {{ op://vwf67dktoxzt77frbh257llrpu/fdhockv5zsg6fzda3iig5zm7dq/storage/secretAccessKey }}
      AWS_ENDPOINT: {{ op://vwf67dktoxzt77frbh257llrpu/fdhockv5zsg6fzda3iig5zm7dq/storage/endpoint }}
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
