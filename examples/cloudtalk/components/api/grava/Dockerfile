# Dockerfile for Grava API
# By default built on Release mode
# To build in Debug mode, build this file with the flag --build-arg DEV=1 --no-cache at the end.

ARG DEV

FROM mcr.microsoft.com/dotnet/aspnet:6.0 AS base
ENV ASPNETCORE_ENVIRONMENT=${DEV:+Development}
ENV ASPNETCORE_ENVIRONMENT=${ASPNETCORE_ENVIRONMENT:-Release}
RUN echo Building $ASPNETCORE_ENVIRONMENT version
ENV BUILD_FLAG=${DEV:+Debug}
ENV BUILD_FLAG=${BUILD_FLAG:-Release}

WORKDIR /app

FROM mcr.microsoft.com/dotnet/sdk:6.0 AS build
# grava
WORKDIR /src
COPY ["./grava/grava.csproj", "grava/"]
RUN dotnet restore "grava/grava.csproj"
COPY ./grava ./grava
WORKDIR "/src/grava"
RUN dotnet build "grava.csproj" -c "$BUILD_FLAG" -o /app/build
# irontest
# WORKDIR /src
# COPY ["./irontest/irontest.csproj", "irontest/"]
# RUN dotnet restore "irontest/irontest.csproj"
# COPY ./irontest ./irontest
# WORKDIR "/src/irontest"
# RUN dotnet build "irontest.csproj" -o /app/build

FROM build AS publish
WORKDIR "/src/grava"
RUN dotnet publish "grava.csproj" -c "$BUILD_FLAG" -o /app/publish
# WORKDIR "/src/irontest"
# RUN dotnet publish "irontest.csproj" -c "$BUILD_FLAG" -o /app/publish

FROM base AS final
WORKDIR /app
ENV ASPNETCORE_URLS http://+:8088
EXPOSE 8088

COPY --from=publish /app/publish .

RUN apt-get update
# RUN apt-get update && apt-get install -y net-tools iputils-ping

ENTRYPOINT ["dotnet", "grava.dll"]