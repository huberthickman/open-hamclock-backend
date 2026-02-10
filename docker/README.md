# Run OHB in a docker container

We always recommend using one of the cloud-based backends. There is load created on the many services hamclock uses to populate it's data. The OHB caches that data and servers it up to the many hamclock deployments.

But if you want to run your own hamclock (for example you are an early adopter and don't want to wait for the cloud-based backends to be deployed), then install your own OHB.

Of course OHB can be deployed on a host OS. But there are many distributions out there and potentially the OHB dependencies can cause issues with your system. The generally accepted method of managing this is to run the service in a container.

You haven't used docker before? Now's your chance! It's not hard and it's great experience.

# What's a docker deployment?

To get OHB to run in docker on your machine, you'll need to:
- install docker on your machine (some distributions like Ubuntu 24.04 install very old docker so you might need to set up the docker repository)
- get the source tree so you can make a docker-compose file
- launch the container with the script from the source tree

# Where are the docker images?

We maintain docker images for the releases in docker hub. When you launch your container it will automatically pull the image from docker hub. If you built the image yourself (with the build scripts), it will automatically use yours.

The build scripts let you create your own image. You might want to do this if you are running bleeding edge code. Or maybe you just want to host your own.

## The steps if I want to use the official image from Docker Hub

Get the source tree from git hub. Visit https://github.com/BrianWilkinsFL/open-hamclock-backend, click on the green "Code" button and copy the https url.

On your computer, clone the repository:
```
git clone https://github.com/BrianWilkinsFL/open-hamclock-backend.git
```

Go into the project directory:
```
cd open-hamclock-backend/docker
```

End sure you are on the release you want to build. For example:
```
git tag
git checkout 1.0
```

Create a docker compose file:
```
# check the options
./build-image.sh -h
# create the compose file
./build-image.sh -c
```

The output will tell you this. If it's your first time running OHB, you'll need to create the storage space for it:
```
./docker-ohb-setup.sh"
```

Finally, start it!
```
docker compose up -d
```

If it's the first time you've run it, it can take a while to populate the data. Nearly all of the current data should be ready in around 15-30 minutes depending on internet speed. In some cases history has to accumulate for all the graphs to look right which could take days. But while you wait days, you'll have a fully functioning hamclock.

## Your hamclock
Ok, so you have a back end. But does your hamclock know about it? Go to the project readme and look for information about the '-b' otion to hamclock.

## Other options
In some cases port 80 might not be available on your OHB server. You can customize the port using the -p option. In the steps above, create the compose file again providing the -p option with your preferred port and run the docker compose up command again.







