ARG ALPINE_VERSION=3.23.3
FROM alpine:${ALPINE_VERSION} AS builder

ARG FIREFLY_VERSION
WORKDIR /app

RUN apk add --no-cache unzip curl

ADD https://github.com/firefly-iii/firefly-iii/releases/download/${FIREFLY_VERSION}/FireflyIII-${FIREFLY_VERSION}.zip ./
RUN unzip FireflyIII-${FIREFLY_VERSION}.zip && \
    rm FireflyIII-${FIREFLY_VERSION}.zip

FROM alpine:${ALPINE_VERSION}

ARG FIREFLY_VERSION
LABEL Maintainer="lzc256 <i@lzc256.com>"
WORKDIR /var/www/html

RUN apk add --no-cache \
    curl nginx supervisor \
    php85 php85-fpm php85-bcmath php85-intl php85-curl php85-zip \
    php85-sodium php85-gd php85-xml php85-mbstring php85-pdo_sqlite \
    php85-session php85-tokenizer php85-dom php85-simplexml php85-xmlwriter php85-openssl php85-phar \
    && apk del python3 \
    && ln -s /usr/bin/php85 /usr/bin/php \
    && rm -rf /var/cache/apk/*

COPY --from=builder --chown=nobody:nobody /app /var/www/html

RUN <<EOF
    set -e
    cd /var/www/html

    # 1. 物理删除所有确定的开发依赖
    # 这步会直接把那些该死的 helpers.php 删掉
    rm -rf \
        vendor/rector vendor/phpstan vendor/larastan vendor/fakerphp \
        vendor/mockery vendor/hamcrest vendor/sebastian vendor/phar-io \
        vendor/theseer vendor/phpunit vendor/nunomaduro/collision \
        vendor/spatie/backtrace vendor/spatie/flare-client-php \
        vendor/spatie/ignition vendor/spatie/laravel-ignition

    # 2. 准备 Composer
    curl -sS https://getcomposer.org/composer-stable.phar -o composer.phar

    # 3. 【核心黑科技】
    # 既然之前的报错是因为索引里还有残留，我们直接删除旧索引，
    # 并且在没有任何旧索引干扰的情况下强行生成全新的、只包含物理存在文件的索引。
    rm -rf vendor/composer vendor/autoload.php

    # 4. 重新生成索引
    # 因为物理文件已经删了，新的 dump-autoload 扫描时根本找不到这些文件夹，
    # 也就绝对不会把 helpers.php 写入新的 autoload_static.php 中。
    php composer.phar dump-autoload --no-dev --optimize --classmap-authoritative

    # 5. 清理碎屑 (注意：不要删除 vendor 根目录下的任何 composer.json)
    find vendor -maxdepth 3 -type d \( -name "tests" -o -name "docs" -o -name ".github" \) -exec rm -rf {} +
    find vendor -maxdepth 3 -type f \( -name "*.md" -o -name "*.txt" -o -name "LICENSE*" -o -name ".gitignore" \) -delete

    # 6. 收尾
    rm composer.phar
    apk del php85-phar
EOF


COPY config/nginx.conf /etc/nginx/nginx.conf
COPY config/conf.d /etc/nginx/conf.d/
ENV PHP_INI_DIR=/etc/php85
COPY config/fpm-pool.conf ${PHP_INI_DIR}/php-fpm.d/www.conf
COPY config/php.ini ${PHP_INI_DIR}/conf.d/custom.ini
COPY config/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

RUN chown -R nobody:nobody /var/www/html /run /var/lib/nginx /var/log/nginx

USER nobody

HEALTHCHECK --timeout=10s CMD curl --silent --fail http://127.0.0.1:8080/fpm-ping || exit 1

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
