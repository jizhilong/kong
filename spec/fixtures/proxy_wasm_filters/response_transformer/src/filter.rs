mod types;

use std::collections::HashMap;
use std::cell::RefCell;
use proxy_wasm::hostcalls::{define_metric, increment_metric, record_metric, get_current_time};
use proxy_wasm::traits::{Context, RootContext, HttpContext};
use proxy_wasm::types::{Action, LogLevel, ContextType, MetricType};
use crate::types::*;
use serde_json;
use log::*;

proxy_wasm::main! {{
   proxy_wasm::set_log_level(LogLevel::Info);
   proxy_wasm::set_root_context(|_| -> Box<dyn RootContext> {
       Box::new(ResponseTransformerContext { config: Config::default() } )
   });
}}

thread_local! {
    static METRICS: Metrics = Metrics::new();
}

struct Metrics {
    metrics: RefCell<HashMap<String, u32>>,
}

impl Metrics {
    fn new() -> Metrics {
        Metrics {
            metrics: RefCell::new(HashMap::new()),
        }
    }

    fn get_counter(&self, name: &str, s_id: &str, r_id: &str) ->u32 {
        self.get_metric(MetricType::Counter, name, s_id, r_id)
    }

    fn get_histogram(&self, name: &str, s_id: &str, r_id: &str) ->u32 {
        self.get_metric(MetricType::Histogram, name, s_id, r_id)
    }

    fn get_metric(&self, metric_type: MetricType, name: &str, s_id: &str, r_id: &str) -> u32 {
        let key = format!("{}_s_id={}_r_id={}", name, s_id, r_id);
        let mut map = self.metrics.borrow_mut();

        match map.get(&key) {
            Some(m_id) => *m_id,
            None => {
                match define_metric(metric_type, &key) {
                    Ok(m_id) => {
                        map.insert(key, m_id);

                        m_id
                    },
                    Err(_) => 0
                }
            }
        }
    }
}


struct ResponseTransformerContext {
    config: Config,
}

impl ResponseTransformerContext {
    fn get_prop(&self, ns: &str, prop: &str) -> String {
        if let Some(addr) = self.get_property(vec![ns, prop]) {
            match std::str::from_utf8(&addr) {
                Ok(value) => value.to_string(),
                Err(_) => "".to_string(),
            }
        } else {
            "".to_string()
        }
    }

    fn increment_metric(&self, name: &str, s_id: &str, r_id: &str) {
        let m_id = METRICS.with(|metrics| metrics.get_counter(name, s_id, r_id));
        increment_metric(m_id, 1).unwrap();
    }

    fn record_histogram(&self, name: &str, s_id: &str, r_id: &str, value: u64) {
        let m_id = METRICS.with(|metrics| metrics.get_histogram(name, s_id, r_id));
        record_metric(m_id, value).unwrap();
    }
}

impl RootContext for ResponseTransformerContext {
    fn on_configure(&mut self, _: usize) -> bool {
        let bytes = self.get_plugin_configuration().unwrap();
        match serde_json::from_slice::<Config>(bytes.as_slice()) {
            Ok(config) => {
                self.config = config;
                true
            },
            Err(e) => {
                error!("failed parsing filter config: {}", e);
                false
            }
        }
    }

    fn create_http_context(&self, _: u32) -> Option<Box<dyn HttpContext>> {
        Some(Box::new(ResponseTransformerContext{
            config: self.config.clone(),
        }))
    }

    fn get_type(&self) -> Option<ContextType> {
        Some(ContextType::HttpContext)
    }
}

impl Context for ResponseTransformerContext {
    fn on_done(&mut self) -> bool {
        true
    }
}

impl HttpContext for ResponseTransformerContext {
    fn on_http_response_headers(&mut self, _num_headers: usize, _end_of_stream: bool) -> Action {
        let s_id = self.get_prop("kong", "service_name");
        let r_id = self.get_prop("kong", "route_name");
        let t0 = get_current_time().unwrap();

        self.config.remove.headers.iter().for_each(|name| {
            info!("[response-transformer] removing header: {}", name);
            self.set_http_response_header(&name, None);

            self.increment_metric("remove", &s_id, &r_id);
        });

        self.config.rename.headers.iter().for_each(|KeyValuePair(from, to)| {
            info!("[response-transformer] renaming header {} => {}", from, to);
            let value = self.get_http_response_header(&from);
            self.set_http_response_header(&from, None);
            self.set_http_response_header(&to, value.as_deref());

            self.increment_metric("rename", &s_id, &r_id);
        });

        self.config.replace.headers.iter().for_each(|KeyValuePair(name, value)| {
            if self.get_http_response_header(&name).is_some() {
                info!("[response-transformer] updating header {} value to {}", name, value);
                self.set_http_response_header(&name, Some(&value));
                self.increment_metric("replace", &s_id, &r_id);
            }
        });

        self.config.add.headers.iter().for_each(|KeyValuePair(name, value)| {
            if self.get_http_response_header(&name).is_none() {
                info!("[response-transformer] adding header {} => {}", name, value);
                self.set_http_response_header(&name, Some(&value));

                self.increment_metric("add", &s_id, &r_id);
            }
        });

        self.config.append.headers.iter().for_each(|KeyValuePair(name, value)| {
            info!("[response-transformer] appending header {} => {}", name, value);
            self.add_http_response_header(&name, &value);

            self.increment_metric("append", &s_id, &r_id);
        });

        let t1 = get_current_time().unwrap();
        let diff = t1.duration_since(t0).unwrap().as_millis();

        self.record_histogram("processing_time", &s_id, &r_id, diff as u64);


        Action::Continue
    }
}
