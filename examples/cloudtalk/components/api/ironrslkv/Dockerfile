FROM mcr.microsoft.com/dotnet/sdk:6.0 AS build
WORKDIR /workspace
RUN export LANG=en_US.UTF-8
RUN apt-get update && apt-get install -y build-essential
RUN apt-get update && apt-get install -y net-tools iputils-ping dnsutils
RUN apt-get update && apt-get install -y curl wget unzip
RUN apt-get update && apt-get install -y nuget mono-devel mono-xbuild
RUN apt-get update && apt-get install -y software-properties-common
RUN apt-get update && apt-get install -y python3
RUN apt-get update && apt-get install -y python3-pip
# The command "./gradlew -q build" exited with code 1. Missing Java.
RUN apt-get update && apt-get install -y default-jre
# Dafny moved to net6.0 but Ironclad is using .net5.0
# https://docs.microsoft.com/en-us/dotnet/core/install/linux-debian
# RUN wget https://packages.microsoft.com/config/debian/11/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
# RUN dpkg -i packages-microsoft-prod.deb
# RUN rm packages-microsoft-prod.deb
# RUN apt-get update && apt-get install -y apt-transport-https
# RUN apt-get update && apt-get install -y aspnetcore-runtime-5.0
RUN pip3 install lit OutputCheck
RUN pip3 install scons
RUN git config --global core.autocrlf input
RUN git clone --branch v0.3 --single-branch https://github.com/microsoft/Ironclad.git
WORKDIR /workspace/Ironclad
WORKDIR /workspace
RUN git clone --branch v3.4.2 --single-branch https://github.com/dafny-lang/dafny.git --recurse-submodules
WORKDIR /workspace/dafny
RUN make exe
RUN pip3 install pre-commit
RUN pre-commit install
RUN make -C /workspace/dafny z3-ubuntu
WORKDIR /workspace/Ironclad/ironfleet
RUN scons --dafny-path=/workspace/dafny/Binaries --no-verify

FROM mcr.microsoft.com/dotnet/aspnet:6.0 AS base
FROM base AS final
WORKDIR /workspace

COPY --from=build /workspace/Ironclad/ironfleet/bin/ /workspace/Ironclad/ironfleet/bin/

COPY ["launch.sh", "/workspace"]
COPY ["certs.sh", "/workspace"]
RUN ["chmod", "+x", "/workspace/launch.sh"]
RUN ["chmod", "+x", "/workspace/certs.sh"]

RUN apt-get update
# RUN apt-get update && apt-get install -y net-tools iputils-ping

ENTRYPOINT ["/bin/bash", "/workspace/launch.sh"]
