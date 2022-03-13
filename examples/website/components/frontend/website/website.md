# frontend/website

Frontend website for user authentication and human-computer interface

## Regenerating and modifying website project (if needed)

- Created CSharp project "website" as per instructions from [Tutorial: Get started with ASP.NET Core](https://docs.microsoft.com/en-us/aspnet/core/getting-started/?view=aspnetcore-5.0)
  - Under `src/frontend`, issue command: `dotnet new webapp -o website`
  - Add `**/wwwroot/lib/*` to `.gitignore`
- Containerize service, including [Running pre-built container images with HTTPS](https://docs.microsoft.com/en-us/aspnet/core/security/docker-https?view=aspnetcore-5.0).
  - Project was missing references to `Microsoft.VisualStudio.Azure.Containers.Tools.Targets (1.10.9)`.
    - Solved with `dotnet add package Microsoft.VisualStudio.Azure.Containers.Tools.Targets --version 1.10.9`. Reference from [nuget](https://www.nuget.org/packages/Microsoft.VisualStudio.Azure.Containers.Tools.Targets/).
  - dotnet dev-certs https -ep %USERPROFILE%\.aspnet\https\aspnetapp.pfx -p { password here }
    - If getting error: `A valid HTTPS certificate is already present.`
      - Clean up with `dotnet dev-certs https --clean` and try again.
  - dotnet dev-certs https --trust
  - Right-click on project, select `Add -> Docker Support...`
- Test project starting with `IIS Express`, and possibly the project name (`website`)
- Start the `Docker` version
  - Build project: right-click the `Dockerfile` and select `Build Docker Image`
    - If getting error message `Volume sharing is not enabled. On the Settings screen in Docker Desktop, click Shared Drives, and select the drive(s) containing your project files.`
      - Open Docker Desktop, and under `Settings`, select `Resources` and then `File Sharing`. Click the button, add the `C:\` drive (or whichever is needed) and the click `Apply & Restart`
    - And now this... Getting error: `failed to solve with frontend dockerfile.v0: failed to read dockerfile: open /var/lib/docker/tmp/buildkit-mount[id]/dockerfile: no such file or directory`
      - Problem is: this is building mounted from Linux, where casing matters! Renamed `Dockerfile` to `dockerfile`
    - Then, you try to start debugging the Docker version, only to get the opposite error.
      - `failed to solve with frontend dockerfile.v0: failed to read dockerfile: open /var/lib/docker/tmp/buildkit-mount[id]/Dockerfile: no such file or directory`
    - Conclusion: either you can start debugging the project (which uses the version with `D` uppercase) or manually build (which uses the version with `d` lowercase). Leave it uppercase and always start debugging... Live is short!

## Running the docker image locally

- You may start debugging the Docker build in Visual Studio. This will run the container usually tagged as `website:dev`, with name `website`. Stopping the debugging may leave it running.
- You can use the CMD script `frontend/website/docker-run-dev`, which will build an image tagged as `yrn42website-prefix/website:latest` and then run it with name `yrn42website-prefix-website`.
  - If coming directly to this step, check if the Docker file sharing is enable for the `C:\` drive (or whichever is needed). Information about sharing is in item above.
  - Check if the password in the command matches the one used when trusting the development certificates.
  - Open in browser: `https://localhost:8001/`

- Local Kubernetes cluster 'docker-desktop'
  - Test if 'Running the docker image locally' works, as per instructions below.
  - If local Kubernetes cluster is enabled, loading can be locally tested
    - `kubectl run --image="yrn42website-prefix/website:latest" yrn42website-prefix-website-test --port=80 --env="DOMAIN=www.yrn42website-domain" --expose=true --image-pull-policy=IfNotPresent`
    - Check if container is running
    - Stop the pod: `kubectl delete pod/yrn42website-prefix-website-test`

Back to main [readme](../../../README.md)
