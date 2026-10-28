FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0-alpine AS build
ARG VERSION=1.0.1
ARG TARGETARCH
WORKDIR /src
COPY Common/ Common/
COPY Server/ Server/
RUN dotnet publish Server/Ahna.Relay.csproj -c Release -a $TARGETARCH --no-self-contained \
    -p:UseAppHost=false -p:Version=$VERSION -o /out

FROM mcr.microsoft.com/dotnet/aspnet:10.0-alpine
ARG VERSION=1.0.1
LABEL org.opencontainers.image.title="Ahna relay" \
      org.opencontainers.image.version="$VERSION" \
      org.opencontainers.image.description="아나(Ahna) 서버"
WORKDIR /app
COPY --from=build /out/ ./
ENV ASPNETCORE_HTTP_PORTS=8080 DOTNET_EnableDiagnostics=0
# 앱 업데이트 파일 보관(이름 있는 볼륨이 이 소유자를 그대로 이어받습니다)
RUN mkdir -p /data && chown $APP_UID /data
VOLUME /data
USER $APP_UID
EXPOSE 8080
HEALTHCHECK --interval=60s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/_ahna/health >/dev/null || exit 1
ENTRYPOINT ["dotnet", "Ahna.Relay.dll"]
