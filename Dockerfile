FROM ruby:latest
RUN mkdir -p /config
COPY salesforce-backup.rb .
ENTRYPOINT ["ruby", "salesforce-backup.rb"]