FROM node:22-alpine
RUN apk add --no-cache unzip
WORKDIR /app
COPY src ./src
EXPOSE 3000
CMD ["node", "src/server.mjs"]
