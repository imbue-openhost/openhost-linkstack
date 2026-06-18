# LinkStack packaged for OpenHost.
#
# Based on the official linkstackorg/linkstack image (Alpine + Apache2 + PHP 8.3
# serving LinkStack at /htdocs on port 80). We add:
#   * python3            – runs the auth-proxy sidecar
#   * the auth-proxy     – terminates the OpenHost-routed :8080, forwards to :80
#   * an SSO middleware  – LinkStack-native owner auto-login (no creds on disk)
#   * a bash supervisor  – first-boot install + run both processes
FROM linkstackorg/linkstack:latest

# The upstream image runs as the unprivileged "apache" user with WORKDIR
# /htdocs. We need root to install packages and to chown the bind-mounted
# persistent data dir at runtime, so switch back to root here; start.sh drops
# privileges to apache for Apache itself.
USER root

RUN apk --no-cache add python3 bash su-exec

# App assets.
COPY auth_proxy.py /opt/openhost/auth_proxy.py
COPY files/OpenHostSso.php /opt/openhost/OpenHostSso.php
COPY start.sh /opt/openhost/start.sh

RUN chmod 0755 /opt/openhost/start.sh /opt/openhost/auth_proxy.py

WORKDIR /htdocs

# OpenHost routes to 8080; the auth-proxy listens there and proxies to Apache.
EXPOSE 8080

ENTRYPOINT ["/opt/openhost/start.sh"]
