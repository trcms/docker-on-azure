FROM docker4x/init-azure:17.06.1-ce-azure1

COPY resources/entry.sh /
RUN sed -i -e 's/v3\.5/edge/g' /etc/apk/repositories && \
    apk upgrade --update-cache --available && \
    apk add --update docker && \
    rm -rf /var/cache/apk/*
