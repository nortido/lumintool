#include <Wire.h>

const uint8_t BH1750_ADDRESS = 0x23;
const uint8_t BH1750_CONTINUOUS_HIGH_RES = 0x10;

void startMeasuring() {
  Wire.beginTransmission(BH1750_ADDRESS);
  Wire.write(BH1750_CONTINUOUS_HIGH_RES);
  Wire.endTransmission();
}

void setup() {
  Serial.begin(115200);
  Wire.begin();
  startMeasuring();
}

void loop() {
  delay(1000);
  if (Wire.requestFrom(BH1750_ADDRESS, (uint8_t)2) != 2) {
    Serial.println("nan");
    startMeasuring();
    return;
  }
  uint16_t raw = (uint16_t)Wire.read() << 8;
  raw |= Wire.read();
  Serial.println(raw / 1.2f);
}
