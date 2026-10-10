FROM node:22-alpine

WORKDIR /app

COPY app/package*.json ./
RUN npm ci --omit=dev

COPY app/server.js ./server.js
COPY app/public ./public

ENV NODE_ENV=production
EXPOSE 3000

USER node
CMD ["node", "server.js"]
