# Docker Image Updates

| Package | Update | Change |
|---|---|---|
| phipzzz/fritzbox-wlan-password-rotator | unknown | `1.4.1
    restart: unless-stopped
    network_mode: bridge
    environment:
      PUID: $PUID
      PGID: $PGID
      TZ:` → `1.4.1` |
| portainer/portainer-ee | unknown | `2.41.0
    deploy:
      resources:
        reservations:
          memory: 32M
    network_mode: bridge
    ports:
      - target: 8000
        published:` → `2.41.1` |
| johngong/aria2 | unknown | `latest
    container_name: aria2
    deploy:
      resources:
        reservations:
          memory: 64M
    restart: unless-stopped
    network_mode: bridge
    ports:
      -` → `1.36.0` |
| p3terx/aria2-pro | unknown | `latest
    container_name: aria2-pro
    deploy:
      resources:
        reservations:
          memory:` → `202209060423` |
| linkstackorg/linkstack | unknown | `latest
    environment:
      TZ:` → `V4` |

## Files Updated

- `Apps/fritzbox-wlan-password-rotator/docker-compose.yml`
- `Apps/Portainer-Business-Edition/docker-compose.yml`
- `Apps/Aria2/docker-compose.yml`
- `Apps/Aria2 Pro/docker-compose.yml`
- `Apps/linkstack/docker-compose.yml`