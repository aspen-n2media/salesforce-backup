FROM ruby:latest
WORKDIR /backup
COPY salesforce-backup.rb .
ENTRYPOINT ["ruby", "salesforce-backup.rb"]