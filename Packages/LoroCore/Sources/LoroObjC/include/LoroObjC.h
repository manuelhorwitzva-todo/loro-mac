#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Corre `block` y atrapa una excepción de Objective-C si la lanza. Devuelve nil si no hubo, o
/// "nombre: motivo". Swift no puede atrapar NSException: AVAudioEngine las lanza (por ejemplo al
/// instalar un tap mientras unos AirPods cambian de modo) y sin esto la app entera se cierra.
NSString * _Nullable LoroCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
