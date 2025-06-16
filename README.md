```
op run --env-file=".env" -- \
docker stack deploy \
-c ghost-beta/docker-stack.yaml \
--detach \
coto-studio
```
