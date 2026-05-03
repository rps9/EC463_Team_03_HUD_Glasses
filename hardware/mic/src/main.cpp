#include <Arduino.h>
#include "driver/i2s.h"

static const i2s_port_t I2S_PORT = I2S_NUM_0;

static const int SAMPLE_RATE = 16000;
static const int CAPTURE_SECONDS = 5;
static const int TOTAL_SAMPLES = SAMPLE_RATE * CAPTURE_SECONDS;

// Your wiring
static const int PIN_I2S_BCLK = 26;
static const int PIN_I2S_LRCLK = 25;
static const int PIN_I2S_DIN = 34;

void setupI2S() {
  i2s_config_t i2s_config = {
      .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
      .sample_rate = SAMPLE_RATE,
      .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
      .channel_format = I2S_CHANNEL_FMT_ONLY_RIGHT,
      .communication_format = I2S_COMM_FORMAT_STAND_I2S,
      .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
      .dma_buf_count = 8,
      .dma_buf_len = 256,
      .use_apll = false,
      .tx_desc_auto_clear = false,
      .fixed_mclk = 0};

  i2s_pin_config_t pin_config = {
      .bck_io_num = PIN_I2S_BCLK,
      .ws_io_num = PIN_I2S_LRCLK,
      .data_out_num = I2S_PIN_NO_CHANGE,
      .data_in_num = PIN_I2S_DIN};

  i2s_driver_install(I2S_PORT, &i2s_config, 0, NULL);
  i2s_set_pin(I2S_PORT, &pin_config);
  i2s_zero_dma_buffer(I2S_PORT);
}

void setup() {
  Serial.begin(921600);
  delay(500);
  Serial.println("Starting I2S mic capture");
  setupI2S();
}

void loop() {
  static bool sent = false;
  if (sent) {
    delay(1000);
    return;
  }

  const int N = 256;
  int32_t samples[N];
  int16_t pcm[N];
  size_t bytesRead = 0;
  int samplesSent = 0;

  Serial.printf("AUDIO_BEGIN %d %d\n", SAMPLE_RATE, TOTAL_SAMPLES);

  while (samplesSent < TOTAL_SAMPLES) {
    i2s_read(I2S_PORT, (void *)samples, sizeof(samples), &bytesRead, portMAX_DELAY);
    int count = bytesRead / 4;

    if (count <= 0) {
      continue;
    }

    if (count > (TOTAL_SAMPLES - samplesSent)) {
      count = TOTAL_SAMPLES - samplesSent;
    }

    for (int i = 0; i < count; i++) {
      int32_t s24 = samples[i] >> 8;
      int32_t s16 = s24 >> 8;

      if (s16 > 32767)
        s16 = 32767;
      if (s16 < -32768)
        s16 = -32768;

      pcm[i] = (int16_t)s16;
    }

    Serial.write((const uint8_t *)pcm, count * sizeof(int16_t));
    samplesSent += count;
  }

  Serial.println();
  Serial.println("AUDIO_END");
  sent = true;
}
