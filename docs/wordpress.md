# WordPress

`manifests/wordpress/wordpress.yaml` runs WordPress and MariaDB in a `wordpress`
namespace, each on its own Cinder volume, and publishes the site at
`https://wordpress.local.my.id` through the shared `public` Gateway.

```bash
kubectl apply -f manifests/observability/gateway.yaml   # listeners, certs
kubectl apply -f manifests/wordpress/wordpress.yaml
kubectl -n wordpress get pods,pvc,httproute
```

The Gateway file must be applied first: the routes reference the
`wordpress-http` and `wordpress-https` listeners, and the HTTPS one needs the
`wordpress-tls` Secret that cert-manager creates from the `wordpress-tls`
Certificate.

## DNS

Point an `A` record for `wordpress.local.my.id` at the Gateway floating IP:

```bash
kubectl -n monitoring get service cilium-gateway-public
```

The certificate issues only after the name resolves, because HTTP-01 validates
from inside the cluster. Watch it settle:

```bash
kubectl -n monitoring get certificate wordpress-tls
kubectl -n monitoring get gateway public     # wordpress-https must be Programmed
```

While the challenge is pending, `wordpress-https` reports
`Invalid CertificateRef` and HTTPS answers `404` from Cilium. That is expected;
the listener recovers on its own once the Secret exists.

## Only wp-content is on the volume

The PVC mounts at `/var/www/html/wp-content`, not at `/var/www/html`. Core
WordPress files come from the image, so changing the image tag really upgrades
the site on the next rollout. Keeping the whole webroot on the volume looks
equivalent but is not: the official entrypoint only copies core into an
**empty** directory, so a volume that already holds a webroot freezes WordPress
at whichever version first filled it, and a new image tag changes nothing.

The volume carries themes, plugins, and uploads only.

## siteurl and home

`siteurl` and `home` in `wp_options` hold the public hostname. They are not
derived from anything, so a fresh install keeps whatever URL you used
(`localhost:8080`) until you change it, and `port-forward` redirects to the
domain instead of serving locally. Test locally by overriding the Host header:

```bash
kubectl -n wordpress port-forward svc/wordpress 8080:80 &
curl -H 'Host: wordpress.local.my.id' http://127.0.0.1:8080/
```

To change them:

```bash
kubectl -n wordpress exec deploy/wordpress-mariadb -- sh -c \
  'mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -D wordpress -e \
   "update wp_options set option_value=\"https://wordpress.local.my.id\" where option_name in (\"siteurl\",\"home\");"'
```

## Upgrade

1. Change the `image` tag. `latest` moves on its own; pin `7.1.5-apache` for
   reproducible redeploys.
2. `kubectl -n wordpress rollout status deploy/wordpress`
3. Run the database upgrade if the new version needs one. WordPress reports
   `Database Update Required` in `/wp-admin/` and refuses to serve until it runs:

```bash
kubectl -n wordpress exec deploy/wordpress -- sh -c \
  'su -s /bin/sh www-data -c "php -r \"require \\\"/var/www/html/wp-load.php\\\"; require_once ABSPATH . \\\"wp-admin/includes/upgrade.php\\\"; wp_upgrade(); echo get_option(\\\"db_version\\\"), PHP_EOL;\""'
```

The undefined `HTTP_HOST` warning it prints is harmless: WP-CLI style calls have
no request context.

Back up first. The database dump and `wp-content` are the only state:

```bash
kubectl -n wordpress exec deploy/wordpress-mariadb -- \
  mariadb-dump -u root -p"$MARIADB_ROOT_PASSWORD" --single-transaction --databases wordpress \
  > wordpress.sql
kubectl -n wordpress exec deploy/wordpress -- tar -czf - -C /var/www/html wp-content > wp-content.tar.gz
```

## Constraints

- One replica each. Both volumes are `ReadWriteOnce`, so the strategy is
  `Recreate`; more replicas need `ReadWriteMany` storage for `wp-content`.
- The passwords in the Secret are placeholders. Replace them before exposing the
  site, and rotate them out of band rather than committing real ones.
- TLS terminates at the Gateway, so `WORDPRESS_CONFIG_EXTRA` maps
  `X-Forwarded-Proto: https` back to `$_SERVER['HTTPS']`. Without it WordPress
  writes `http://` URLs into the database and redirects in a loop.
- `siteurl` and `home` are not automatic; see [siteurl and home](#siteurl-and-home).
