ARG ALPINE_VERSION=3.23.3
FROM alpine:${ALPINE_VERSION}

ARG FIREFLY_VERSION
LABEL Maintainer="lzc256 <i@lzc256.com>"
LABEL Description="Firefly III"
# Setup document root
WORKDIR /var/www/html

# ENV http_proxy http://192.168.1.50:7890
# ENV https_proxy http://192.168.1.50:7890
# Install packages and remove default server definition
RUN apk add --no-cache \
  curl \
  nginx \
  supervisor \
  php85 \
  php85-fpm \
  php85-bcmath \
  php85-intl \
  php85-curl \
  php85-zip \
  php85-sodium \
  php85-gd \
  php85-xml \
  php85-mbstring \
  php85-pdo_sqlite \
  php85-session
  # php85-openssl \
  # php85-fileinfo \
  # php85-simplexml \
  # php85-tokenizer \
  # php85-xmlwriter \
  # php85-dom \
  # php85-shmop \
  # php85-pgsql \
  # php85-pdo_pgsql \

RUN apk add --no-cache unzip

RUN ln -s /usr/bin/php85 /usr/bin/php

# Configure nginx - http
COPY config/nginx.conf /etc/nginx/nginx.conf
# Configure nginx - default server
COPY config/conf.d /etc/nginx/conf.d/

# Configure PHP-FPM
ENV PHP_INI_DIR /etc/php85
COPY config/fpm-pool.conf ${PHP_INI_DIR}/php-fpm.d/www.conf
COPY config/php.ini ${PHP_INI_DIR}/conf.d/custom.ini

# Configure supervisord
COPY config/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
# Make sure files/folders needed by the processes are accessable when they run under the nobody user
RUN chown -R nobody:nobody /var/www/html /run /var/lib/nginx /var/log/nginx

# Switch to use a non-root user from here on
USER nobody

# Add application
# COPY --chown=nobody src/ /var/www/html/

ADD --chown=nobody https://github.com/firefly-iii/firefly-iii/releases/download/${FIREFLY_VERSION}/FireflyIII-${FIREFLY_VERSION}.zip /var/www/html/

RUN unzip FireflyIII-${FIREFLY_VERSION}.zip && rm FireflyIII-${FIREFLY_VERSION}.zip

# Expose the port nginx is reachable on
EXPOSE 8080

# Let supervisord start nginx & php-fpm
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]

# Configure a healthcheck to validate that everything is up&running
HEALTHCHECK --timeout=10s CMD curl --silent --fail http://127.0.0.1:8080/fpm-ping || exit 1
