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

    # 1. 物理删除：先精准砍掉那些绝对不需要的开发包
    # 这样它们就不会在下一步的 dump 中被扫描到
    rm -rf \
        vendor/rector vendor/phpstan vendor/larastan vendor/fakerphp \
        vendor/mockery vendor/hamcrest vendor/sebastian vendor/phar-io \
        vendor/theseer vendor/phpunit vendor/nunomaduro/collision \
        vendor/spatie/backtrace vendor/spatie/flare-client-php \
        vendor/spatie/ignition vendor/spatie/laravel-ignition

    # 2. 准备 Composer
    curl -sS https://getcomposer.org/composer-stable.phar -o composer.phar

    # 3. 关键：在不删除旧索引的情况下，强行刷新
    # 我们加上 --no-scripts 避免触发可能报错的钩子
    # 虽然物理文件没了，但 Composer 会发现文件缺失并从新生成的索引中剔除它们
    php composer.phar dump-autoload --no-dev --optimize --classmap-authoritative --no-scripts

    # 4. 二次清理：清理掉刚才删除操作可能留下的空目录
    find vendor -maxdepth 2 -type d -empty -delete

    # 5. 清理碎屑（注意：绝对不要在 vendor 下执行 -name "composer.json" -delete）
    # 很多包的类加载依赖它自己的 composer.json
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
