FROM docker.io/library/swift:5.10

WORKDIR /workspace

COPY . /workspace

CMD ["swift", "test"]
