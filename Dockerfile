FROM ruby:latest
COPY salesforce-backup.rb .
ENTRYPOINT ["ruby", "salesforce-backup.rb"]