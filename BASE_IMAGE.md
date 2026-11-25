# Base Images

## What we have

Currently there are base image distros, Red Hat UBI, and Ubuntu LTS based images.

Depending on the MariaDB version, the base image will be the latest LTS available at the time the MariaDB GA version got released.

## Staying consistent

MariaDB is itself used as a base image by some of our users. To keep the user experience consistent for those using a stable release series like 10.11, that version will stay constant until the base image or the MariaDB release series become end of life.

If the MariaDB release series become EOL, that's easy, there's no more releases.

If the base image goes EOL, then the "Staying consistent" will need to change. Docker Official Images are role models of container best practices and continuing to release on an EOL base image is not best practice. On top of that MariaDB upstream will stop releasing packages for EOL base images.

### The transition

In a release, (or two), before the EOL of a base image, there will be a second image available on the new base. For example, MariaDB 10.11 has a base instance of Ubuntu 22.04 Jammy. This LTS release of Ubuntu has an end of life in April 2027. So that users have new base image they can migrate to in the months before April 2027, there is a MariaDB 10.11 container image based on Ubuntu 24.04 (Noble) with an explicit tag suffix of `-noble`.

### Concluding the transition

EOL base images will be removed as updated versions at some point between their EOL date and the next release which will include only the new LTS base image. MariaDB uses a few system libraries who's vulnerabilities or defects may impact MariaDB users. After the point at which the base image is EOL, there will be no operating system updates to fix those vulnerability or defects. It will be up to users to use supported base images if this is important. A default tradeoff in favour of a stable base image at the risk of a late vulnerability/defect affecting EOL base image. This is being made by default, and if it isn't your trade-off, the alternate base image will exist.

### Example transition

To take the 10.11 example from the previous paragraph, some point about April 2027 there will be image tags (noting their equality on the same line):
* 10.11.21-noble, 10.11-noble
* 10.11.21-jammy, 10.11-jammy, 10-jammy, 10.11.20, 10.11, 10

The next release after that will be:
* 10.11.22-noble, 10.11-noble, 10-noble, 10.11.21, 10.11, 10

## Maintainer notes

The Buildbot CI needs to be kept in sync with the base images here. The `hasDockerLibrary` function of [utils.py](https://github.com/MariaDB/buildbot/blob/78282875e572b830688a29fb20ec1c391ec48515/utils.py#L474-L475) handles the mapping of the base OS builder so that the triggers of the Docker Library occur when the package is created.

For when transitioning is occuring, ensure that the suffix mapping is in the Buildbot scripts/docker-library\*.sh mappings and dual versions will be processed.
