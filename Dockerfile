FROM ruby:3.2

RUN cd /tmp && \
  wget --quiet https://bitbucket.org/ariya/phantomjs/downloads/phantomjs-2.1.1-linux-x86_64.tar.bz2 && \
  tar -xf phantomjs-2.1.1-linux-x86_64.tar.bz2 && \
  mv phantomjs-2.1.1-linux-x86_64/bin/phantomjs /usr/local/bin && \
  rm -rf phantomjs*

WORKDIR /usr/src/app

RUN mkdir -p ./lib/message_bus
COPY lib/message_bus/version.rb ./lib/message_bus
COPY Gemfile *.gemspec ./
RUN bundle install

COPY . .

CMD ["rake"]
