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

Until it resolves, the HTTP listener already redirects to HTTPS but the browser
gets an invalid certificate, and the ACME challenge stays `pending` with
`no such host`. The site itself is reachable in the meantime:

```bash
kubectl -n wordpress port-forward svc/wordpress 8080:80
```

## Only wp-content is on the volume

The PVC mounts at `/var/www/html/wp-content`, not at `/var/www/html`. Core
WordPress files come from the image, so changing the image tag really upgrades
the site on the next rollout. Keeping the whole webroot on the volume looks
equivalent but is not: the official entrypoint only copies core into an
**empty** directory, so a volume that already holds a webroot freezes WordPress
at whichever version first filled it, and a new image tag changes nothing.

The volume carries themes, plugins, and uploads only.

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
- `siteurl` and `home` in `wp_options` must match the public hostname. They are
  set to `http://localhost:8080` by the initial install; change them before
  pointing DNS at the site.
