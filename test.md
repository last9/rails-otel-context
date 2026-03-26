
1. span attributes -> are set differentyl for each span

2. resource attributes -> are set once, and carried on all spans within trace

eg. resource attributes
- service name
- deployment env
- k8s attributes

## our setup today

service name -> circle_production
deployment env - blank

## last9

discover -> services (service and environment) 
circle_production -> all endpoints all spans, all db calls, all external calls

## goal

team specific service dashboards

1. payment service, some env
2. analytics service
3. infra service
4. common service (circle_production)

## what to do

1. resource attribute -> payment for payment request lifecycle
2. resource attribute -> analytics for analytics request lifecycle
3. some fallback -> circle_production



# config/initializers/otel.rb

resource_attributes.service -> circle_production

# application_controller.rb

# add team attribute
# app pod ->  OTEL_EXPORTER_OTLP_ENDPOINT = otel_collector:4318
current_span.add_span_attribute(team, "something")

## Otel Collector (Circle infrastructure) otel_collector:4318

- enrich spans with k8s attributes by adding resouce details
- read the endpoint(code.namespace) => service.name -> payment.
- send to last9 endpoint

## Last9 control plane

1. read each span
2. if span.span_attributes["team"] exists, then use that service, else continue(circle_production)

## What we need
1. only the request knows which is the team (controller/endpoint/whatever)
2. when the request is beign processerd, there is trace context for that request
3. trace context (resource attributes, spans, span attrbiutes)
4. is it possible to update resource attributes per request ()